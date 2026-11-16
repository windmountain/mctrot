// Moves every recorded GPS point so the walk is centered on Union Square,
// keeping its shape and distances. For test walks recorded far from the
// route: afterwards they look like Manhattan walks to the map, visit
// detection and stats.
//
//   MCTROT_DB=... node src/dislocate.ts plan    describe, change nothing
//   MCTROT_DB=... node src/dislocate.ts apply   move the points
//
// On the box, run `mctrot-dislocate` instead: it asks first and stops the
// services around the change (host/api.nix). When later steps add tables
// with coordinates (posts), they must be moved here too.
import { pathToFileURL } from "node:url";
import { type Db, openDb } from "./db.ts";

export const UNION_SQUARE = { lat: 40.735556, lon: -73.990556 };

type Box = { minLat: number; maxLat: number; minLon: number; maxLon: number; n: number };

// What a move would do; null when there are no points to move.
export type Plan = {
  points: number;
  from: { lat: number; lon: number };
  to: { lat: number; lon: number };
  distanceKm: number;
} | null;

const rad = (deg: number) => (deg * Math.PI) / 180;

function haversineKm(a: { lat: number; lon: number }, b: { lat: number; lon: number }) {
  const h =
    Math.sin(rad(b.lat - a.lat) / 2) ** 2 +
    Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(rad(b.lon - a.lon) / 2) ** 2;
  return 2 * 6371 * Math.asin(Math.sqrt(h));
}

export function plan(db: Db, to = UNION_SQUARE): Plan {
  const box = db
    .prepare(
      `select min(lat) as minLat, max(lat) as maxLat, min(lon) as minLon,
              max(lon) as maxLon, count(*) as n from points`,
    )
    .get() as Box;
  if (box.n === 0) return null;
  const from = { lat: (box.minLat + box.maxLat) / 2, lon: (box.minLon + box.maxLon) / 2 };
  return { points: box.n, from, to, distanceKm: haversineKm(from, to) };
}

// Each point keeps its north/east offset in metres from the walk's center.
// Latitude degrees are the same length everywhere; longitude degrees
// shrink with cos(latitude), so east-west offsets are rescaled.
export function apply(db: Db, to = UNION_SQUARE): Plan {
  const p = plan(db, to);
  if (p === null) return null;
  const scale = Math.cos(rad(p.from.lat)) / Math.cos(rad(to.lat));
  db.prepare(
    `update points set lat = @toLat + (lat - @fromLat),
                       lon = @toLon + (lon - @fromLon) * @scale`,
  ).run({ toLat: to.lat, fromLat: p.from.lat, toLon: to.lon, fromLon: p.from.lon, scale });
  return p;
}

function describe(p: Plan): string {
  if (p === null) return "No points recorded; nothing to move.";
  const f = (c: { lat: number; lon: number }) => `${c.lat.toFixed(6)}, ${c.lon.toFixed(6)}`;
  return [
    `${p.points} points, centered on ${f(p.from)}`,
    `move to ${f(p.to)} (Union Square), ${p.distanceKm.toFixed(1)} km away`,
  ].join("\n");
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const mode = process.argv[2];
  if (mode !== "plan" && mode !== "apply") {
    console.error("usage: dislocate.ts plan|apply  (database from MCTROT_DB)");
    process.exit(2);
  }
  // "never": this tool must not reset a database whose schema differs.
  const { db } = openDb(process.env.MCTROT_DB ?? "dev.sqlite", "never");
  if (mode === "plan") {
    console.log(describe(plan(db)));
  } else {
    const p = db.transaction(() => apply(db))();
    console.log(p === null ? describe(p) : `Moved ${p.points} points.`);
  }
  db.close();
}
