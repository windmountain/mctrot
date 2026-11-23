import type { Db } from "./db.ts";
// From the server's pairs.ts: how long a DoubleTake clip waited for its
// partner, and a pair's order.
const PAIR_WAIT_MS = 10 * 60_000;
type PairOrder = "AB" | "BA";
import { type LatLon, positionFromDb } from "./visits.ts";

export type Media = {
  url: string; // photo: full size; video: .mp4; voice: .m4a; pair: the cut in its order
  thumbUrl: string | null; // photo
  posterUrl: string | null; // video
  width: number | null;
  height: number | null;
  durationMs: number | null;
};

export type Post = {
  id: string;
  ts: number;
  type: "text" | "photo" | "video" | "voice" | "pair";
  text: string | null;
  media: Media | null;
  // A DoubleTake pair: its order, and both clips for a player that shows
  // them side by side. `media` is the cut (one video) in that order.
  pair: { order: PairOrder; a: Clip; b: Clip } | null;
  // Where I was when I made it, from the GPS track; null when unknown
  // (yet: like visits, it's worked out each time, so late GPS fills it in).
  at: LatLon | null;
};

export type Clip = { url: string; posterUrl: string | null };

type Row = {
  id: string;
  ts: number;
  type: Post["type"];
  text: string | null;
  pair_order: PairOrder | null;
  alt_media_path: string | null;
  alt_poster_path: string | null;
  media_path: string | null;
  thumb_path: string | null;
  poster_path: string | null;
  width: number | null;
  height: number | null;
  duration_ms: number | null;
};

// The newest ready posts first, with where each was made. `mediaUrl` is
// where the media folder is served, e.g. "https://media.mctrot.nyc".
// A DoubleTake clip isn't shown on its own once it's in a pair, nor while
// it may still be waiting for its partner (src/pairs.ts).
export function recentPosts(db: Db, mediaUrl: string, limit = 50, now = Date.now()): Post[] {
  const rows = db
    .prepare(
      `select id, ts, type, text, pair_order, alt_media_path, alt_poster_path,
              media_path, thumb_path, poster_path, width, height, duration_ms
       from posts
       where hidden = 0 and status = 'ready' and paired_into is null
         and not (type = 'video' and letter is not null and received_at > ?)
       order by ts desc limit ?`,
    )
    .all(now - PAIR_WAIT_MS, limit) as Row[];
  const url = (path: string | null) => (path === null ? null : `${mediaUrl}/${path}`);
  const clips = db.prepare("select letter, media_path, poster_path from posts where paired_into = ?");
  return rows.map((r) => {
    const where = positionFromDb(db, r.ts);
    const ba = r.type === "pair" && r.pair_order === "BA";
    let pair: Post["pair"] = null;
    if (r.type === "pair") {
      const byLetter = new Map(
        (clips.all(r.id) as { letter: string; media_path: string; poster_path: string | null }[]).map((c) => [
          c.letter,
          { url: url(c.media_path)!, posterUrl: url(c.poster_path) },
        ]),
      );
      const a = byLetter.get("A");
      const b = byLetter.get("B");
      if (a && b) pair = { order: r.pair_order ?? "AB", a, b };
    }
    return {
      id: r.id,
      ts: r.ts,
      type: r.type,
      text: r.text,
      pair,
      media:
        r.media_path === null
          ? null
          : {
              url: url(ba ? r.alt_media_path : r.media_path)!,
              thumbUrl: url(r.thumb_path),
              posterUrl: url(ba ? r.alt_poster_path : r.poster_path),
              width: r.width,
              height: r.height,
              durationMs: r.duration_ms,
            },
      at: where.kind === "at" ? { lat: where.at.lat, lon: where.at.lon } : null,
    };
  });
}
