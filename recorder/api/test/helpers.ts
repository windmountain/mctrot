import { buildApp } from "../src/app.ts";
import { openDb } from "../src/db.ts";

export const TOKEN = "test-token";
export const auth = { authorization: `Bearer ${TOKEN}` };

// setup({}) runs without an ingest token configured.
export function setup({ ingestToken }: { ingestToken?: string } = { ingestToken: TOKEN }) {
  const { db } = openDb(":memory:");
  const app = buildApp({
    db,
    version: "abc1234",
    startedAt: new Date(Date.now() - 5000),
    ingestToken,
  });
  return { db, app };
}

// A location as Overland sends it.
export function feature(timestamp: string, lon = -73.9857, lat = 40.7484, extra = {}) {
  return {
    type: "Feature",
    geometry: { type: "Point", coordinates: [lon, lat] },
    properties: {
      timestamp,
      horizontal_accuracy: 5,
      speed: 1.4,
      battery_level: 0.8,
      motion: ["walking"],
      device_id: "zach-iphone",
      ...extra,
    },
  };
}
