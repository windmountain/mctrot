import assert from "node:assert/strict";
import { test } from "node:test";
import { openDb } from "../src/db.ts";
import { apply, plan, UNION_SQUARE } from "../src/dislocate.ts";

// A small walk in Seattle (about 47.6°N, where longitude degrees are
// noticeably shorter than in New York).
const WALK = [
  [47.6062, -122.3321],
  [47.6070, -122.3321],
  [47.6070, -122.3300],
  [47.6050, -122.3300],
];

function seeded() {
  const { db } = openDb(":memory:");
  const insert = db.prepare(
    "insert into points (ts, lat, lon, received_at) values (?, ?, ?, 0)",
  );
  WALK.forEach(([lat, lon], i) => insert.run(i * 30_000, lat, lon));
  return db;
}

const coords = (db: ReturnType<typeof seeded>) =>
  db.prepare("select lat, lon from points order by ts").all() as { lat: number; lon: number }[];

// Equirectangular metres between two points; fine at walk scale.
function metres(a: { lat: number; lon: number }, b: { lat: number; lon: number }) {
  const k = 111_320;
  const midLat = ((a.lat + b.lat) / 2) * (Math.PI / 180);
  return Math.hypot((b.lat - a.lat) * k, (b.lon - a.lon) * k * Math.cos(midLat));
}

test("centers the walk's bounding box on Union Square", () => {
  const db = seeded();
  apply(db);
  const after = plan(db);
  assert.ok(after !== null);
  assert.ok(Math.abs(after.from.lat - UNION_SQUARE.lat) < 1e-9);
  assert.ok(Math.abs(after.from.lon - UNION_SQUARE.lon) < 1e-9);
});

test("keeps the walk's shape and distances", () => {
  const db = seeded();
  const before = coords(db);
  apply(db);
  const after = coords(db);
  for (let i = 1; i < before.length; i++) {
    const was = metres(before[i - 1]!, before[i]!);
    const now = metres(after[i - 1]!, after[i]!);
    assert.ok(Math.abs(now - was) < 0.5, `leg ${i}: ${was.toFixed(1)} m became ${now.toFixed(1)} m`);
  }
});

test("running it twice moves nothing the second time", () => {
  const db = seeded();
  apply(db);
  const once = coords(db);
  const second = apply(db);
  assert.ok(second !== null && second.distanceKm < 1e-6);
  coords(db).forEach((c, i) => {
    assert.ok(Math.abs(c.lat - once[i]!.lat) < 1e-9 && Math.abs(c.lon - once[i]!.lon) < 1e-9);
  });
});

test("an empty database is left alone", () => {
  const { db } = openDb(":memory:");
  assert.equal(apply(db), null);
});
