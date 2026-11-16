import assert from "node:assert/strict";
import { test } from "node:test";
import { GAP_MS, segments, simplify } from "../src/track.ts";
import { auth, feature, setup } from "./helpers.ts";

// A walk north along a straight line, a fix a second.
const straight = (n: number, t0 = 0) =>
  Array.from({ length: n }, (_, i) => ({ ts: t0 + i * 1000, lat: 40.73 + i * 1e-5, lon: -73.99 }));

test("a straight walk simplifies to its two ends", () => {
  const out = simplify(straight(500));
  assert.equal(out.length, 2);
});

test("corners are kept", () => {
  const north = straight(100);
  const last = north[north.length - 1]!;
  const east = Array.from({ length: 100 }, (_, i) => ({ ts: last.ts + (i + 1) * 1000, lat: last.lat, lon: last.lon + (i + 1) * 1e-5 }));
  const out = simplify([...north, ...east]);
  assert.equal(out.length, 3);
  assert.deepEqual(out[1], last);
});

test("a long gap splits the path; a lone fix draws nothing", () => {
  const a = straight(10);
  const b = straight(10, 10_000 + GAP_MS + 1);
  const lone = { ts: b[9]!.ts + GAP_MS + 1, lat: 40.8, lon: -73.9 };
  const out = segments([...a, ...b, lone]);
  assert.equal(out.length, 2);
  assert.deepEqual(out[0]![0], [40.73, -73.99]);
});

test("/live's track: the last day before any attempt, then the attempt's, without inaccurate fixes", async () => {
  const { app } = await setup();
  const iso = (msAgo: number) => new Date(Date.now() - msAgo).toISOString();
  const locations = [
    feature(iso(3 * 86_400_000), -73.99, 40.70), // days ago: not shown
    feature(iso(120_000), -73.99, 40.73),
    feature(iso(90_000), -73.97, 40.75, { horizontal_accuracy: 200 }), // indoors: dropped
    feature(iso(60_000), -73.99, 40.74),
  ];
  await app.inject({ method: "POST", url: "/ingest", headers: auth, payload: { locations } });
  assert.deepEqual((await app.inject({ url: "/live" })).json().track, [
    [
      [40.73, -73.99],
      [40.74, -73.99],
    ],
  ]);
  await app.inject({ method: "POST", url: "/attempts/start", headers: auth });
  assert.deepEqual((await app.inject({ url: "/live" })).json().track, [], "nothing walked yet this attempt");
});
