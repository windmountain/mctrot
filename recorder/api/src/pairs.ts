// DoubleTake pairs. DoubleTake records the back and front cameras at once
// and saves two videos, …_A.MOV and …_B.MOV, with the same time and the
// same length. I upload both, in either order, without saying they belong
// together; the worker pairs them here, by time and length alone (no
// metadata from the files), into one 'pair' post.
//
// A clip named like DoubleTake's waits up to PAIR_WAIT_MS for its partner
// before /live shows it on its own, so a pair doesn't flash up as a single
// video first. A pair starts in order AB; the upload page can swap it to BA.
import { randomUUID } from "node:crypto";
import type { Db } from "./db.ts";

export const PAIR_WAIT_MS = 10 * 60_000;
// Both clips stop together; their lengths can differ by a frame or two.
export const PAIR_LENGTH_TOLERANCE_MS = 100;

export type Letter = "A" | "B";
export type PairOrder = "AB" | "BA";

// "11162026_121306_A.MOV" -> "A". Null for anything else.
export function letterFromFilename(name: string | null | undefined): Letter | null {
  const m = /_([AB])\.[A-Za-z0-9]+$/.exec(name ?? "");
  return m ? (m[1] as Letter) : null;
}

type Clip = { id: string; ts: number; duration_ms: number | null; letter: Letter | null; received_at: number };

// Called when a video is ready. If an unpaired ready video has the same
// time and length, makes the pair post (processing) and its job, and
// returns the pair's id.
export function tryPair(db: Db, clipId: string, now = Date.now()): string | null {
  return db.transaction(() => {
    const clip = db
      .prepare(
        `select id, ts, duration_ms, letter, received_at from posts
         where id = ? and type = 'video' and status = 'ready' and paired_into is null`,
      )
      .get(clipId) as Clip | undefined;
    if (!clip || clip.duration_ms === null) return null;
    const partner = db
      .prepare(
        `select id, ts, duration_ms, letter, received_at from posts
         where type = 'video' and status = 'ready' and paired_into is null and id != ?
           and ts = ? and abs(duration_ms - ?) <= ?
         order by received_at limit 1`,
      )
      .get(clip.id, clip.ts, clip.duration_ms, PAIR_LENGTH_TOLERANCE_MS) as Clip | undefined;
    if (!partner) return null;

    // Which is A: the filenames say, if both survived the upload and
    // differ; otherwise the one that arrived first.
    const byLetters = clip.letter && partner.letter && clip.letter !== partner.letter;
    const [a, b] = byLetters
      ? clip.letter === "A"
        ? [clip, partner]
        : [partner, clip]
      : [partner, clip]; // partner was received first (it was waiting)
    const pairId = `pair-${randomUUID()}`;
    db.prepare(
      `insert into posts (id, ts, type, status, pair_order, received_at)
       values (?, ?, 'pair', 'processing', 'AB', ?)`,
    ).run(pairId, clip.ts, now);
    const setLetter = db.prepare("update posts set paired_into = ?, letter = ? where id = ?");
    setLetter.run(pairId, "A", a.id);
    setLetter.run(pairId, "B", b.id);
    db.prepare(
      `insert into jobs (post_id, upload_path, content_type, created_at, updated_at)
       values (?, '', 'pair', ?, ?)`,
    ).run(pairId, now, now);
    return pairId;
  })();
}

// A pair's clips, A first.
export function pairClips(db: Db, pairId: string): { id: string; media_path: string | null; poster_path: string | null }[] {
  return db
    .prepare("select id, media_path, poster_path from posts where paired_into = ? order by letter")
    .all(pairId) as { id: string; media_path: string | null; poster_path: string | null }[];
}

// If a pair can't be made, its clips go back to being videos of their own.
export function unpair(db: Db, pairId: string) {
  db.prepare("update posts set paired_into = null where paired_into = ?").run(pairId);
}
