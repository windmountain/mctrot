// What the recorder recorded (recorded.json, dumped from the event's
// redacted database), loaded into an in-memory SQLite database with the
// server's table and column names, so the server code here queries it as
// it queried the real one. Node's own SQLite (node:sqlite): no packages.
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";

export type Db = DatabaseSync;

export type Recorded = {
  source: string;
  points: [ts: number, lat: number, lon: number, accuracy: number | null][];
  visitTaps: number[];
  posts: Record<string, string | number | null>[];
  weather: (Record<string, number | null> & { current: Record<string, number> })[];
  guestComments: { id: number; postId: string; name: string; link: string | null; text: string; ts: number }[];
  guestLikes: { postId: string; ts: number }[];
};

export function readRecorded(path: string): Recorded {
  return JSON.parse(readFileSync(path, "utf8")) as Recorded;
}

// Only the columns the export's queries use.
const POST_COLUMNS = [
  "id", "ts", "type", "text", "status", "media_path", "thumb_path", "poster_path", "width", "height", "duration_ms",
  "letter", "paired_into", "pair_order", "alt_media_path", "alt_poster_path", "hidden", "received_at",
];
const WEATHER_COLUMNS = [
  "fetched_at", "observed_at", "temperature_f", "feels_like_f", "humidity_pct", "precipitation_in", "weather_code",
  "cloud_cover_pct", "wind_mph", "gust_mph", "wind_from_deg", "is_day",
];

export function openRecorded(recorded: Recorded): Db {
  const db = new DatabaseSync(":memory:");
  db.exec(`
    create table points (ts integer primary key, lat real not null, lon real not null, accuracy real);
    create table visit_taps (ts integer not null);
    create table posts (${POST_COLUMNS.join(", ")});
    create table weather (${WEATHER_COLUMNS.join(", ")}, raw text not null);
  `);
  const insert = (table: string, columns: string[], rows: unknown[][]) => {
    const statement = db.prepare(`insert into ${table} (${columns.join(", ")}) values (${columns.map(() => "?").join(", ")})`);
    db.exec("begin");
    for (const row of rows) statement.run(...(row as (string | number | null)[]));
    db.exec("commit");
  };
  insert("points", ["ts", "lat", "lon", "accuracy"], recorded.points);
  insert("visit_taps", ["ts"], recorded.visitTaps.map((ts) => [ts]));
  insert("posts", POST_COLUMNS, recorded.posts.map((p) => POST_COLUMNS.map((c) => p[c] ?? null)));
  // The sky reads Open-Meteo's reply from raw: here, just the part kept.
  insert(
    "weather",
    [...WEATHER_COLUMNS, "raw"],
    recorded.weather.map((w) => [...WEATHER_COLUMNS.map((c) => w[c] ?? null), JSON.stringify({ current: w.current })]),
  );
  return db;
}
