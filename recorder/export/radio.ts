// McTrot radio's program (radio-program.json, the same program.json
// Liquidsoap played from) and what was on when: the server's radio.ts,
// without its zod schemas and file watcher.
type Who = { artist: string; title: string };

export type RadioProgram = {
  file: string;
  startsAt: number; // seconds since epoch
  endsAt: number;
  before: Who;
  after: Who;
  entries: (Who & {
    offset: number; // seconds from the show's start
    duration: number;
    kind: "track" | "break";
    album: string | null;
    year: string | null;
  })[];
};

type Slot = {
  artist: string;
  title: string;
  album: string | null;
  year: string | null;
  from: number | null; // ms since epoch; null: on since before anyone knew
  to: number | null; // null: on from now on
  kind: "track" | "break" | "holding";
};

export type Radio = {
  status: "before" | "on" | "after";
  startsAt: number;
  endsAt: number;
  current: Slot;
  next: Slot | null;
} | null;

export function readProgram(json: string): RadioProgram {
  const p = JSON.parse(json) as RadioProgram;
  return { ...p, entries: p.entries.map((e) => ({ ...e, album: e.album ?? null, year: e.year ?? null })) };
}

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
  const slot = (i: number): Slot => {
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
