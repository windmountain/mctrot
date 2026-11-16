import { z } from "zod";
import type { Db } from "./db.ts";

// One location from Overland: a GeoJSON Point feature. Only the fields we
// keep are checked; anything else Overland adds is ignored.
// https://github.com/aaronpk/Overland-iOS#api
const OverlandFeature = z.object({
  type: z.literal("Feature"),
  geometry: z.object({
    type: z.literal("Point"),
    coordinates: z.tuple([
      z.number().min(-180).max(180), // lon
      z.number().min(-90).max(90), // lat
    ], z.number()),
  }),
  properties: z.object({
    // Overland writes offsets without a colon (-0500); Date.parse copes.
    timestamp: z.string().refine((s) => !Number.isNaN(Date.parse(s))),
    horizontal_accuracy: z.number().optional(),
    speed: z.number().optional(),
    battery_level: z.number().optional(),
  }),
});

export const OverlandBatch = z.object({ locations: z.array(z.unknown()) });

export type Point = {
  ts: number;
  lat: number;
  lon: number;
  accuracy: number | null;
  speed: number | null;
  battery: number | null;
};

// iOS reports -1 for "unknown" speed, accuracy and battery.
const known = (n: number | undefined) => (n === undefined || n < 0 ? null : n);

export function parseFeature(raw: unknown): Point | null {
  const f = OverlandFeature.safeParse(raw);
  if (!f.success) return null;
  const [lon, lat] = f.data.geometry.coordinates;
  const p = f.data.properties;
  return {
    ts: Date.parse(p.timestamp),
    lat,
    lon,
    accuracy: known(p.horizontal_accuracy),
    speed: known(p.speed),
    battery: known(p.battery_level),
  };
}

export type IngestResult = { stored: number; duplicates: number; skipped: number };

export function storePoints(db: Db, raws: unknown[], now = Date.now()): IngestResult {
  const insert = db.prepare(
    `insert or ignore into points (ts, lat, lon, accuracy, speed, battery, received_at)
     values (@ts, @lat, @lon, @accuracy, @speed, @battery, @receivedAt)`,
  );
  const result: IngestResult = { stored: 0, duplicates: 0, skipped: 0 };
  db.transaction(() => {
    for (const raw of raws) {
      const point = parseFeature(raw);
      if (!point) {
        result.skipped++;
        continue;
      }
      if (insert.run({ ...point, receivedAt: now }).changes === 1) result.stored++;
      else result.duplicates++;
    }
  })();
  return result;
}

export function lastPoints(db: Db, n: number) {
  const rows = db
    .prepare(`select * from points order by ts desc limit ?`)
    .all(n) as (Point & { received_at: number })[];
  return rows.map((r) => ({
    at: new Date(r.ts).toISOString(),
    lat: r.lat,
    lon: r.lon,
    accuracy: r.accuracy,
    speed: r.speed,
    battery: r.battery,
    receivedAt: new Date(r.received_at).toISOString(),
  }));
}
