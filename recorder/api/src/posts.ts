import type { Db } from "./db.ts";
import { type LatLon, positionFromDb } from "./visits.ts";

export const MAX_TEXT = 1000;

export type Post = {
  id: string;
  ts: number;
  type: "text";
  text: string;
  // Where I was when I wrote it, from the GPS track; null when unknown
  // (yet: like visits, it's worked out each time, so late GPS fills it in).
  at: LatLon | null;
};

// `id` comes from the phone's outbox, so a retried upload is harmless;
// returns false if this id was already recorded.
export function recordTextPost(db: Db, id: string, ts: number, text: string, now = Date.now()): boolean {
  return (
    db
      .prepare(
        `insert or ignore into posts (id, ts, type, text, received_at)
         values (?, ?, 'text', ?, ?)`,
      )
      .run(id, ts, text, now).changes === 1
  );
}

// The newest posts first, with where each was written.
export function recentPosts(db: Db, limit = 50): Post[] {
  const rows = db
    .prepare("select id, ts, type, text from posts where hidden = 0 order by ts desc limit ?")
    .all(limit) as Omit<Post, "at">[];
  return rows.map((r) => {
    const where = positionFromDb(db, r.ts);
    return { ...r, at: where.kind === "at" ? { lat: where.at.lat, lon: where.at.lon } : null };
  });
}
