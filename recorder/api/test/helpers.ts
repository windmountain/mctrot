import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildApp } from "../src/app.ts";
import { openDb } from "../src/db.ts";
import type { Mail } from "../src/guests/mail.ts";
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
export const ORIGIN = "https://api.example.test";

export const SITE = "https://site.example.test";

// Guests' emails land in `mail` instead of being sent.
export async function setup({ ingestToken }: { ingestToken?: string } = { ingestToken: TOKEN }) {
  const { db } = openDb(":memory:");
  const mail: Mail[] = [];
  const mediaDir = mkdtempSync(join(tmpdir(), "mctrot-media-"));
  const app = await buildApp({
    db,
    plan: PLAN,
    version: "abc1234",
    startedAt: new Date(Date.now() - 5000),
    ingestToken,
    sessionSecret: "test-session-secret-0123456789abcdef",
    origin: ORIGIN,
    rpID: "example.test",
    // recorder/post/; the Nix build points this at its copy.
    postDir: process.env.MCTROT_POST_DIR ?? new URL("../../post/", import.meta.url).pathname,
    uploadDir: mkdtempSync(join(tmpdir(), "mctrot-uploads-")),
    mediaUrl: "https://media.example.test",
    mediaDir,
    guests: { siteOrigin: SITE, mailer: async (m) => void mail.push(m) },
  });
  return { db, app, mediaDir, mail };
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
