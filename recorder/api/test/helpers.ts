import { buildApp } from "../src/app.ts";
import { openDb } from "../src/db.ts";
import type { RoutePlan } from "../src/plan.ts";

export const TOKEN = "test-token";
export const auth = { authorization: `Bearer ${TOKEN}` };

// Three stores around Union Square, each well over 150 m from the others.
export const PLAN: RoutePlan = {
  stores: [
    { id: "a", name: "A", address: "1 Test St", lat: 40.7359, lon: -73.9911, arrive: null, depart: null },
    { id: "b", name: "B", address: "2 Test St", lat: 40.7390, lon: -73.9870, arrive: null, depart: null },
    { id: "c", name: "C", address: "3 Test St", lat: 40.7320, lon: -73.9860, arrive: null, depart: null },
  ],
  track: [],
};

// setup({}) runs without an ingest token configured.
export function setup({ ingestToken }: { ingestToken?: string } = { ingestToken: TOKEN }) {
  const { db } = openDb(":memory:");
  const app = buildApp({
    db,
    plan: PLAN,
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
