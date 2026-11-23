// Export a finished event's database as one JSON file for a static replay
// page: everything /live showed, each item with its own time, so the page
// can work out what /live would have shown at any moment by filtering.
//
// It reuses the server's own code (track simplification, visit matching,
// posts, weather, sky, sun, radio), run once over the whole day, so the
// replay agrees with what /live showed. Kept for reference after the event.
//
//   node src/export-archive.ts <db.sqlite> <route-plan.json> <program.json> <out.json> [skips.json]
//
// skips.json (e.g. recorder/skips-2026-11-21.json): McDonald's skipped
// because they weren't open, which /post had no button for; each becomes
// a "skipped" check-in at its store, replacing any unmatched tap within
// DOUBLE_TAP_MS of it (a Check In pressed for want of Skip).
//
// Run in the recorder flake's shell (`nix develop` in recorder/) for Node 26.
// The database is opened read-only. What's left out on purpose: guest
// emails, sessions and codes; passkeys; jobs; battery, speed and server
// receive times of points; hidden or failed posts; weather's raw replies.
import Database from "better-sqlite3";
import { readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";
import { gzipSync } from "node:zlib";
import type { Db } from "./db.ts";
import { loadPlan } from "./plan.ts";
import { recentPosts } from "./posts.ts";
import { nowPlaying, RadioProgram } from "./radio.ts";
import { sky } from "./sky.ts";
import { newYorkDate, sunTimes } from "./sun.ts";
import { GAP_MS, MAX_ACCURACY_M, simplify } from "./track.ts";
import { DOUBLE_TAP_MS, matchVisits, positionFromDb, tapsBetween } from "./visits.ts";
import { compass, type SkyInputs, WEATHER_POINT, WMO } from "./weather.ts";

export const FORMAT = "mctrot-archive";
export const VERSION = 1;
// Media paths become relative to the archive page: `media/<path>`.
const MEDIA_URL = "media";
// The sky is worked out on a grid this fine; the page shows the latest.
const SKY_STEP_MS = 5 * 60_000;
// Weather readings older than this before the first event are left out.
const WEATHER_LEAD_MS = 60 * 60_000;

const [dbPath, planPath, programPath, outPath, skipsPath] = process.argv.slice(2);
if (!dbPath || !planPath || !programPath || !outPath) {
  console.error("usage: node src/export-archive.ts <db.sqlite> <route-plan.json> <program.json> <out.json> [skips.json]");
  process.exit(2);
}

const db: Db = new Database(dbPath, { readonly: true, fileMustExist: true });
const plan = loadPlan(planPath);
const program = RadioProgram.parse(JSON.parse(readFileSync(programPath, "utf8")));

const round6 = (deg: number) => Math.round(deg * 1e6) / 1e6;
const round1 = (x: number | null) => (x === null ? null : Math.round(x * 10) / 10);
const time = (iso: string | null) => (iso === null ? null : Date.parse(iso));

// Points: every fix, as [ts, lat, lon, accuracy]. The page's "position at t"
// is the last of these at or before t, as /live's was the latest.
const rawPoints = db.prepare("select ts, lat, lon, accuracy from points order by ts").all() as {
  ts: number;
  lat: number;
  lon: number;
  accuracy: number | null;
}[];
const points = rawPoints.map((p) => [p.ts, round6(p.lat), round6(p.lon), round1(p.accuracy)] as const);

// Track: /live's segments (src/track.ts), with each kept vertex's time, so
// the page can cut the path at t. Simplified over the whole day; cutting
// it at t differs from simplifying up to t by under TOLERANCE_M.
const goodFixes = rawPoints.filter((p) => p.accuracy === null || p.accuracy <= MAX_ACCURACY_M);
const track: [number, number, number][][] = [];
{
  let current: typeof goodFixes = [];
  const finish = () => {
    if (current.length >= 2) track.push(simplify(current).map((f) => [f.ts, round6(f.lat), round6(f.lon)]));
    current = [];
  };
  for (const f of goodFixes) {
    const prev = current[current.length - 1];
    if (prev && f.ts - prev.ts > GAP_MS) finish();
    current.push(f);
  }
  finish();
}

// Visits, matched as /live matched them at the end of the day. Before late
// GPS arrived some showed as pending; the archive keeps the final answer.
type Skip = { storeId: string; at: string; why: string };
const skips: Skip[] = skipsPath ? (JSON.parse(readFileSync(skipsPath, "utf8")) as { skips: Skip[] }).skips : [];
for (const skip of skips) {
  if (!plan.stores.some((s) => s.id === skip.storeId)) throw new Error(`skip of ${skip.storeId}: no such store in the plan`);
  if (Number.isNaN(Date.parse(skip.at))) throw new Error(`skip of ${skip.storeId}: bad time ${skip.at}`);
}
const skipTimes = skips.map((s) => Date.parse(s.at));
const matched = matchVisits(tapsBetween(db, 0, Number.MAX_SAFE_INTEGER), plan.stores, (ts) => positionFromDb(db, ts));
for (const skip of skips) {
  if (matched.some((v) => v.status === "matched" && v.storeId === skip.storeId)) {
    throw new Error(`skip of ${skip.storeId}: it was checked in at`);
  }
}
const visits = [
  ...matched.filter((v) => v.status === "matched" || !skipTimes.some((t) => Math.abs(v.tapTs - t) < DOUBLE_TAP_MS)),
  ...skips.map((s) => ({ tapTs: Date.parse(s.at), status: "skipped" as const, storeId: s.storeId })),
].sort((a, b) => a.tapTs - b.tapTs);

// Posts, oldest first, with when the server got each (the page can reveal a
// post at `ts`, when it was made, or `receivedAt`, when /live first had it).
const received = new Map(
  (db.prepare("select id, received_at from posts").all() as { id: string; received_at: number }[]).map((r) => [
    r.id,
    r.received_at,
  ]),
);
const posts = recentPosts(db, MEDIA_URL, 1_000_000, Number.MAX_SAFE_INTEGER)
  .reverse()
  .map((p) => ({ ...p, receivedAt: received.get(p.id)! }));

// The window the scrubber covers: the first to the last thing recorded.
const eventTimes = [
  ...rawPoints.map((p) => p.ts),
  ...posts.flatMap((p) => [p.ts, p.receivedAt]),
  ...visits.map((v) => v.tapTs),
];
const window = { from: Math.min(...eventTimes), to: Math.max(...eventTimes) };

// Weather: each reading as /live showed it (src/weather.ts latestWeather),
// oldest first. The page shows the latest with fetchedAt <= t.
type WeatherRow = {
  fetched_at: number;
  observed_at: number;
  temperature_f: number | null;
  feels_like_f: number | null;
  humidity_pct: number | null;
  precipitation_in: number | null;
  weather_code: number | null;
  cloud_cover_pct: number | null;
  wind_mph: number | null;
  gust_mph: number | null;
  wind_from_deg: number | null;
  is_day: number | null;
  raw: string;
};
const weatherRows = db
  .prepare("select * from weather where fetched_at >= ? and fetched_at <= ? order by fetched_at")
  .all(window.from - WEATHER_LEAD_MS, window.to) as WeatherRow[];
const weather = weatherRows.map((r) => ({
  observedAt: r.observed_at,
  fetchedAt: r.fetched_at,
  temperatureF: r.temperature_f,
  feelsLikeF: r.feels_like_f,
  humidityPct: r.humidity_pct,
  precipitationIn: r.precipitation_in,
  summary: r.weather_code === null ? null : (WMO[r.weather_code] ?? null),
  cloudCoverPct: r.cloud_cover_pct,
  windMph: r.wind_mph,
  gustMph: r.gust_mph,
  windFrom: r.wind_from_deg === null ? null : compass(r.wind_from_deg),
  isDay: r.is_day === null ? null : r.is_day === 1,
}));

// The sky (src/sky.ts) needs the raw reply's cloud layers; as
// latestSkyInputs, but for each reading.
const skyInputs = (r: WeatherRow): SkyInputs => {
  let current: Record<string, unknown> = {};
  try {
    current = (JSON.parse(r.raw) as { current?: Record<string, unknown> }).current ?? {};
  } catch {
    // An unreadable raw reply only loses the extra detail.
  }
  const n = (k: string) => (typeof current[k] === "number" ? (current[k] as number) : null);
  return {
    observedAt: r.observed_at,
    cloudCoverPct: r.cloud_cover_pct,
    lowPct: n("cloud_cover_low"),
    midPct: n("cloud_cover_mid"),
    highPct: n("cloud_cover_high"),
    visibilityFt: n("visibility"),
  };
};
const readingAt = (t: number) => {
  let latest: WeatherRow | null = null;
  for (const r of weatherRows) if (r.fetched_at <= t) latest = r;
  return latest;
};
const skies = [];
for (let t = Math.floor(window.from / SKY_STEP_MS) * SKY_STEP_MS; t <= window.to + SKY_STEP_MS; t += SKY_STEP_MS) {
  const r = readingAt(t);
  skies.push(sky(t, WEATHER_POINT.lat, WEATHER_POINT.lon, r && skyInputs(r)));
}

// Sun times for each New York date the window touches.
const sun: Record<string, ReturnType<typeof sunTimes>> = {};
for (let t = window.from; t <= window.to + 86_400_000; t += 3_600_000) {
  const date = newYorkDate(Math.min(t, window.to));
  sun[date] ??= sunTimes(date, WEATHER_POINT.lat, WEATHER_POINT.lon);
}

// Radio: every slot of the day's show, from the server's own nowPlaying.
// The page shows the slot with from <= t < to (null from/to: open-ended).
// Each step lands 1 ms past the slot's end: slot times are rounded to the
// millisecond and nowPlaying compares unrounded offsets, so landing exactly
// on `to` can return the same slot again.
const before = nowPlaying(program, Math.round(program.startsAt * 1000) - 1)!;
const slots = [before.current];
for (let t = before.startsAt; ; ) {
  const r = nowPlaying(program, t)!;
  if (r.status !== "on") {
    // The holding loop after the show (daily() has moved on to tomorrow's).
    slots.push(nowPlaying(program, before.endsAt - 1)!.next!);
    break;
  }
  slots.push(r.current);
  t = r.current.to! + 1;
}
const radio = { startsAt: before.startsAt, endsAt: before.endsAt, slots };

// Guests: approved comments with the name and link they chose to show, and
// likes as times only.
const comments = db
  .prepare(
    `select c.id, c.post_id as postId, coalesce(a.display_name, 'Guest') as name, a.link, c.text,
            c.created_at as ts
     from guest_comments c join guest_accounts a on a.id = c.account_id
     where c.status = 'approved' order by c.created_at`,
  )
  .all();
const likes = db.prepare("select post_id as postId, created_at as ts from guest_likes order by created_at").all();

const archive = {
  format: FORMAT,
  version: VERSION,
  exportedAt: Date.now(),
  source: basename(dbPath),
  window,
  place: WEATHER_POINT,
  stores: plan.stores.map(({ id, name, address, lat, lon, arrive, depart }) => ({
    id,
    name,
    address,
    lat,
    lon,
    arrive: time(arrive),
    depart: time(depart),
  })),
  plannedTrack: plan.track,
  points,
  track,
  visits,
  posts,
  weather,
  sky: skies,
  sun,
  radio,
  guests: { comments, likes },
};

const json = JSON.stringify(archive);
writeFileSync(outPath, json);

// Sizes, whole and by section, so it's clear what the page would load.
const kb = (n: number) => `${(n / 1024).toFixed(1)} KB`;
const size = (v: unknown) => {
  const s = JSON.stringify(v);
  return `${kb(Buffer.byteLength(s)).padStart(9)} ${kb(gzipSync(s).length).padStart(9)} gz`;
};
const fmt = (ms: number) => new Date(ms).toLocaleString("en-US", { timeZone: "America/New_York" });
console.log(`wrote ${outPath}`);
console.log(`window ${fmt(window.from)} to ${fmt(window.to)}`);
console.log(`total      ${size(archive)}`);
for (const [k, v] of Object.entries(archive)) {
  const n = Array.isArray(v) ? ` (${v.length})` : "";
  if (typeof v === "object" && v !== null) console.log(`  ${(k + n).padEnd(22)} ${size(v)}`);
}
const media = posts.flatMap((p) =>
  [p.media?.url, p.media?.thumbUrl, p.media?.posterUrl, p.pair?.a.url, p.pair?.a.posterUrl, p.pair?.b.url, p.pair?.b.posterUrl]
    .filter((u): u is string => typeof u === "string"),
);
console.log(`media files referenced: ${media.length}`);
for (const m of media) console.log(`  ${m}`);
db.close();
