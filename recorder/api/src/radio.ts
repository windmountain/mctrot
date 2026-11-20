import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { z } from "zod";

// McTrot radio's program: what's on when, for /live's now playing. It's
// the same program.json Liquidsoap plays from (station/program.liq), made
// by tools/radio_program.py and uploaded by hand to the station folder
// next to its show file, so it's read from disk, not deployed: again
// whenever it changes. Like Liquidsoap, no program, or a program whose show
// file isn't there, is off air.
const Who = z.object({ artist: z.string(), title: z.string() });

export const RadioProgram = z.object({
  file: z.string().min(1),
  startsAt: z.number().describe("Seconds since epoch"),
  endsAt: z.number(),
  before: Who,
  after: Who,
  entries: z.array(
    Who.extend({
      offset: z.number().describe("Seconds from the show's start"),
      duration: z.number(),
      kind: z.enum(["track", "break"]),
      album: z.string().nullable().default(null),
      year: z.string().nullable().default(null),
    }),
  ),
});

export type RadioProgram = z.infer<typeof RadioProgram>;

// The program at `path`, read again when the file changes; null without
// one, or while it can't be used (a bad or half-uploaded file is logged,
// not fatal: it's uploaded by hand mid-event).
export function programReader(
  path: string | undefined,
  warn: (message: string) => void = () => {},
): () => RadioProgram | null {
  let seen: string | null = null;
  let program: RadioProgram | null = null;
  return () => {
    if (path === undefined) return null;
    let stamp: string;
    try {
      const st = statSync(path);
      stamp = `${st.mtimeMs} ${st.size}`;
    } catch {
      seen = null;
      program = null;
      return null;
    }
    if (stamp !== seen) {
      seen = stamp;
      try {
        program = RadioProgram.parse(JSON.parse(readFileSync(path, "utf8")));
      } catch (err) {
        warn(`radio program ${path} unusable: ${(err as Error).message}`);
        program = null;
      }
    }
    if (program && !existsSync(join(dirname(path), program.file))) return null;
    return program;
  };
}

const ms = (what: string) => z.number().int().describe(`${what}, ms since epoch`);

const Slot = z.object({
  artist: z.string(),
  title: z.string(),
  album: z.string().nullable(),
  year: z.string().nullable().describe('The album\'s year: "1995"'),
  from: ms("Starts").nullable().describe("Null: on since before anyone knew"),
  to: ms("Ends").nullable().describe("Null: on from now on"),
  kind: z.enum(["track", "break", "holding"]).describe("holding: the silent loop before and after the show"),
});

export const Radio = z
  .object({
    status: z.enum(["before", "on", "after"]).describe("after: only with no entries, now the show airs daily"),
    startsAt: ms("Today's show's start (or tomorrow's, once today's is over)"),
    endsAt: ms("That show's end"),
    current: Slot.describe("What's on now"),
    next: Slot.nullable().describe("What's on at current.to; null after the show"),
  })
  .nullable()
  .describe("McTrot radio's now playing, from its program (station/program.json); null without a program");

export type Radio = z.infer<typeof Radio>;

const DAY = 86400;

// The show airs every day at the program's time, not only on its date
// (station/program.liq does the same): today's, if it's on or still to
// come, else tomorrow's. Days are 24 hours, so across a daylight saving
// change it airs an hour off.
export function daily(program: RadioProgram, now: number): RadioProgram {
  const length = program.endsAt - program.startsAt;
  const t = now / 1000;
  let startsAt = program.startsAt + DAY * Math.floor((t - program.startsAt) / DAY);
  if (t >= startsAt + length) startsAt += DAY;
  return { ...program, startsAt, endsAt: startsAt + length };
}

export function nowPlaying(original: RadioProgram | null, now: number): Radio {
  if (original === null) return null;
  const program = daily(original, now);
  const startsAt = Math.round(program.startsAt * 1000);
  const endsAt = Math.round(program.endsAt * 1000);
  const slot = (i: number): z.infer<typeof Slot> => {
    const e = program.entries[i]!;
    const from = startsAt + Math.round(e.offset * 1000);
    const next = program.entries[i + 1];
    return {
      artist: e.artist,
      title: e.title,
      album: e.album,
      year: e.year,
      from,
      to: next ? startsAt + Math.round(next.offset * 1000) : endsAt,
      kind: e.kind,
    };
  };
  const holding = { album: null, year: null, kind: "holding" as const };
  const before = { ...program.before, ...holding, from: null, to: startsAt };
  const after = { ...program.after, ...holding, from: endsAt, to: null };
  const first = program.entries.length ? slot(0) : after;
  if (now < startsAt) return { status: "before", startsAt, endsAt, current: before, next: first };
  if (now >= endsAt || program.entries.length === 0) return { status: "after", startsAt, endsAt, current: after, next: null };
  // The last entry starting at or before now.
  const offset = (now - startsAt) / 1000;
  let i = 0;
  while (i + 1 < program.entries.length && program.entries[i + 1]!.offset <= offset) i++;
  return {
    status: "on",
    startsAt,
    endsAt,
    current: slot(i),
    next: i + 1 < program.entries.length ? slot(i + 1) : after,
  };
}
