// What the upload page lists as sent, and how I fix mistakes from the road:
// delete a check-in or a post (for good: the row, its job and its files),
// or edit a text post's text.
import { rmSync } from "node:fs";
import { join } from "node:path";
import type { Db } from "./db.ts";

export type SentItem =
  | { kind: "checkin"; id: string; ts: number }
  | {
      kind: "post";
      id: string;
      ts: number;
      type: "text" | "photo" | "video" | "voice";
      text: string | null;
      status: "processing" | "ready" | "failed";
      error: string | null;
      thumbUrl: string | null; // photo thumbnail or video poster
    };

// Newest first, check-ins and posts together, whatever their status.
export function sentItems(db: Db, mediaUrl: string, limit = 100): SentItem[] {
  const checkins = (
    db.prepare("select id, ts from visit_taps order by ts desc limit ?").all(limit) as { id: string; ts: number }[]
  ).map((r): SentItem => ({ kind: "checkin", id: r.id, ts: r.ts }));
  type Row = {
    id: string;
    ts: number;
    type: "text" | "photo" | "video" | "voice";
    text: string | null;
    status: "processing" | "ready" | "failed";
    error: string | null;
    preview: string | null;
  };
  const posts = (
    db
      .prepare(
        `select id, ts, type, text, status, error, coalesce(thumb_path, poster_path) as preview
         from posts order by ts desc limit ?`,
      )
      .all(limit) as Row[]
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
// (jobs.ts).
export function deletePost(db: Db, id: string, mediaDir: string): boolean {
  const deleted = db.transaction(() => {
    const job = db.prepare("select upload_path from jobs where post_id = ?").get(id) as
      | { upload_path: string }
      | undefined;
    db.prepare("delete from jobs where post_id = ?").run(id);
    const gone = db.prepare("delete from posts where id = ?").run(id).changes === 1;
    return gone ? { uploadPath: job?.upload_path } : null;
  })();
  if (!deleted) return false;
  if (deleted.uploadPath) {
    rmSync(deleted.uploadPath, { force: true });
    rmSync(`${deleted.uploadPath}.json`, { force: true });
  }
  // The id comes from the phone; never let it name a path outside.
  if (/^[\w-]+$/.test(id)) rmSync(join(mediaDir, id), { recursive: true, force: true });
  return true;
}

// Only a text post's text can change; media posts have none to edit.
export function editPost(db: Db, id: string, text: string): "edited" | "missing" | "not-text" {
  const row = db.prepare("select type from posts where id = ?").get(id) as { type: string } | undefined;
  if (!row) return "missing";
  if (row.type !== "text") return "not-text";
  db.prepare("update posts set text = ? where id = ?").run(text, id);
  return "edited";
}
