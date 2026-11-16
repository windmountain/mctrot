// The processing queue: an upload becomes a "processing" post and a job;
// the worker (src/worker.ts) takes jobs one at a time and makes the post
// ready, or failed with a reason.
import { rmSync } from "node:fs";
import { join } from "node:path";
import type { Db } from "./db.ts";
import { type MediaKind, processMedia } from "./media.ts";

export const MAX_ATTEMPTS = 3;

// Called when an upload finishes. The post id comes from the phone's
// outbox, so a re-sent upload doesn't make a second post or job.
export function queueUpload(
  db: Db,
  post: { id: string; ts: number; kind: MediaKind },
  upload: { path: string; contentType: string },
  now = Date.now(),
): boolean {
  return db.transaction(() => {
    const created =
      db
        .prepare(
          `insert or ignore into posts (id, ts, type, status, received_at)
           values (?, ?, ?, 'processing', ?)`,
        )
        .run(post.id, post.ts, post.kind, now).changes === 1;
    if (created) {
      db.prepare(
        `insert into jobs (post_id, upload_path, content_type, created_at, updated_at)
         values (?, ?, ?, ?, ?)`,
      ).run(post.id, upload.path, upload.contentType, now, now);
    }
    return created;
  })();
}

type Job = { id: number; post_id: string; upload_path: string; content_type: string; attempts: number };

// A job left "running" by a worker that died is put back in the queue.
export function requeueAbandoned(db: Db): number {
  return db.prepare("update jobs set status = 'queued' where status = 'running'").run().changes;
}

function claim(db: Db, now: number): (Job & { kind: MediaKind }) | undefined {
  return db.transaction(() => {
    const job = db
      .prepare(
        `select j.*, p.type as kind from jobs j join posts p on p.id = j.post_id
         where j.status = 'queued' order by j.id limit 1`,
      )
      .get() as (Job & { kind: MediaKind }) | undefined;
    if (job) {
      db.prepare("update jobs set status = 'running', attempts = attempts + 1, updated_at = ? where id = ?").run(
        now,
        job.id,
      );
      job.attempts += 1;
    }
    return job;
  })();
}

// Processes the oldest queued job, if any; returns whether there was one.
export async function processNext(db: Db, mediaDir: string, now = Date.now): Promise<boolean> {
  const job = claim(db, now());
  if (!job) return false;
  try {
    const out = await processMedia(job.kind, job.upload_path, mediaDir, job.post_id);
    const stillThere = db.transaction(() => {
      const updated = db
        .prepare(
          `update posts set status = 'ready', error = null, media_path = ?, thumb_path = ?,
             poster_path = ?, width = ?, height = ?, duration_ms = ? where id = ?`,
        )
        .run(out.mediaPath, out.thumbPath, out.posterPath, out.width, out.height, out.durationMs, job.post_id);
      db.prepare("update jobs set status = 'done', error = null, updated_at = ? where id = ?").run(now(), job.id);
      return updated.changes === 1;
    })();
    // Deleted from the upload page while it was being processed.
    if (!stillThere) rmSync(join(mediaDir, job.post_id), { recursive: true, force: true });
    // The upload (and the tus file store's .json beside it) is no longer needed.
    rmSync(job.upload_path, { force: true });
    rmSync(`${job.upload_path}.json`, { force: true });
  } catch (err) {
    const error = err instanceof Error ? err.message : String(err);
    const giveUp = job.attempts >= MAX_ATTEMPTS;
    db.transaction(() => {
      db.prepare("update jobs set status = ?, error = ?, updated_at = ? where id = ?").run(
        giveUp ? "failed" : "queued",
        error,
        now(),
        job.id,
      );
      if (giveUp) db.prepare("update posts set status = 'failed', error = ? where id = ?").run(error, job.post_id);
    })();
  }
  return true;
}

// Where each of these posts is: for the upload page's outbox.
export function postStatuses(db: Db, ids: string[]): Record<string, { status: string; error: string | null }> {
  const get = db.prepare("select status, error from posts where id = ?");
  const out: Record<string, { status: string; error: string | null }> = {};
  for (const id of ids) {
    const row = get.get(id) as { status: string; error: string | null } | undefined;
    out[id] = row ?? { status: "missing", error: null };
  }
  return out;
}
