// What the upload page lists as sent, and how I fix mistakes from the road:
// delete a check-in or a post (for good: the row, its job and its files),
// edit a text post's text, or swap a DoubleTake pair's order (AB or BA:
// the only way to set it; uploads always start AB).
import { rmSync } from "node:fs";
import { join } from "node:path";
import type { Db } from "./db.ts";
import { PAIR_WAIT_MS, type PairOrder } from "./pairs.ts";

export type SentItem =
  | { kind: "checkin"; id: string; ts: number }
  | {
      kind: "post";
      id: string;
      ts: number;
      type: "text" | "photo" | "video" | "voice" | "pair";
      text: string | null;
      status: "processing" | "ready" | "failed";
      error: string | null;
      thumbUrl: string | null; // photo thumbnail, video poster, or the pair's in its order
      order: PairOrder | null; // a pair's
      waitingForPair: boolean; // a DoubleTake clip not yet shown, waiting for its partner
    };

// Newest first, check-ins and posts together, whatever their status.
// A pair's two clips are part of the pair, not items of their own.
export function sentItems(db: Db, mediaUrl: string, limit = 100, now = Date.now()): SentItem[] {
  const checkins = (
    db.prepare("select id, ts from visit_taps order by ts desc limit ?").all(limit) as { id: string; ts: number }[]
  ).map((r): SentItem => ({ kind: "checkin", id: r.id, ts: r.ts }));
  type Row = {
    id: string;
    ts: number;
    type: "text" | "photo" | "video" | "voice" | "pair";
    text: string | null;
    status: "processing" | "ready" | "failed";
    error: string | null;
    preview: string | null;
    pair_order: PairOrder | null;
    waiting: number;
  };
  const posts = (
    db
      .prepare(
        `select id, ts, type, text, status, error, pair_order,
                case when pair_order = 'BA' then alt_poster_path else coalesce(thumb_path, poster_path) end as preview,
                (type = 'video' and letter is not null and status = 'ready' and received_at > ?) as waiting
         from posts where paired_into is null order by ts desc limit ?`,
      )
      .all(now - PAIR_WAIT_MS, limit) as Row[]
  ).map(
    (r): SentItem => ({
      kind: "post",
      id: r.id,
      ts: r.ts,
      type: r.type,
      text: r.text,
      status: r.status,
      error: r.error,
      thumbUrl: r.preview === null ? null : `${mediaUrl}/${r.preview}`,
      order: r.pair_order,
      waitingForPair: r.waiting === 1,
    }),
  );
  return [...checkins, ...posts].sort((a, b) => b.ts - a.ts).slice(0, limit);
}

export function deleteCheckin(db: Db, id: string): boolean {
  return db.prepare("delete from visit_taps where id = ?").run(id).changes === 1;
}

// Deletes a post with its processing job, its upload if it's still
// waiting, and its media folder. If the worker is processing it right
// now, the worker notices the post is gone and removes what it made
// (jobs.ts). Deleting a pair deletes both its clips too.
export function deletePost(db: Db, id: string, mediaDir: string): boolean {
  const deleted = db.transaction(() => {
    const clips = db.prepare("select id from posts where paired_into = ?").pluck().all(id) as string[];
    const ids = [id, ...clips];
    const uploads: string[] = [];
    for (const postId of ids) {
      const job = db.prepare("select upload_path from jobs where post_id = ?").get(postId) as
        | { upload_path: string }
        | undefined;
      if (job?.upload_path) uploads.push(job.upload_path);
      db.prepare("delete from jobs where post_id = ?").run(postId);
    }
    for (const clip of clips) db.prepare("delete from posts where id = ?").run(clip);
    const gone = db.prepare("delete from posts where id = ?").run(id).changes === 1;
    return gone ? { ids, uploads } : null;
  })();
  if (!deleted) return false;
  for (const upload of deleted.uploads) {
    rmSync(upload, { force: true });
    rmSync(`${upload}.json`, { force: true });
  }
  // Ids come from the phone; never let one name a path outside.
  for (const postId of deleted.ids) {
    if (/^[\w-]+$/.test(postId)) rmSync(join(mediaDir, postId), { recursive: true, force: true });
  }
  return true;
}

// A text post's text, or a pair's order; nothing else can change.
export type Edit = { text: string } | { order: PairOrder };

export function editPost(db: Db, id: string, edit: Edit): "edited" | "missing" | "wrong-type" {
  const row = db.prepare("select type from posts where id = ?").get(id) as { type: string } | undefined;
  if (!row) return "missing";
  if ("text" in edit) {
    if (row.type !== "text") return "wrong-type";
    db.prepare("update posts set text = ? where id = ?").run(edit.text, id);
  } else {
    if (row.type !== "pair") return "wrong-type";
    db.prepare("update posts set pair_order = ? where id = ?").run(edit.order, id);
  }
  return "edited";
}
