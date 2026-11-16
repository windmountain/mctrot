import type { Db } from "./db.ts";
import { type LatLon, positionFromDb } from "./visits.ts";

export const MAX_TEXT = 1000;

export type Media = {
  url: string; // photo: full size; video: .mp4; voice: .m4a
  thumbUrl: string | null; // photo
  posterUrl: string | null; // video
  width: number | null;
  height: number | null;
  durationMs: number | null;
};

export type Post = {
  id: string;
  ts: number;
  type: "text" | "photo" | "video" | "voice";
  text: string | null;
  media: Media | null;
  // Where I was when I made it, from the GPS track; null when unknown
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

type Row = {
  id: string;
  ts: number;
  type: Post["type"];
  text: string | null;
  media_path: string | null;
  thumb_path: string | null;
  poster_path: string | null;
  width: number | null;
  height: number | null;
  duration_ms: number | null;
};

// The newest ready posts first, with where each was made. `mediaUrl` is
// where the media folder is served, e.g. "https://media.mctrot.nyc".
export function recentPosts(db: Db, mediaUrl: string, limit = 50): Post[] {
  const rows = db
    .prepare(
      `select id, ts, type, text, media_path, thumb_path, poster_path, width, height, duration_ms
       from posts where hidden = 0 and status = 'ready' order by ts desc limit ?`,
    )
    .all(limit) as Row[];
  const url = (path: string | null) => (path === null ? null : `${mediaUrl}/${path}`);
  return rows.map((r) => {
    const where = positionFromDb(db, r.ts);
    return {
      id: r.id,
      ts: r.ts,
      type: r.type,
      text: r.text,
      media:
        r.media_path === null
          ? null
          : {
              url: url(r.media_path)!,
              thumbUrl: url(r.thumb_path),
              posterUrl: url(r.poster_path),
              width: r.width,
              height: r.height,
              durationMs: r.duration_ms,
            },
      at: where.kind === "at" ? { lat: where.at.lat, lon: where.at.lon } : null,
    };
  });
}
