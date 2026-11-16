import assert from "node:assert/strict";
import { test } from "node:test";
import { auth, feature, setup, TOKEN } from "./helpers.ts";

const ingest = (app: Awaited<ReturnType<typeof setup>>["app"], locations: unknown[], headers = auth) =>
  app.inject({ method: "POST", url: "/ingest", headers, payload: { locations } });

const count = (db: Awaited<ReturnType<typeof setup>>["db"]) =>
  db.prepare("select count(*) from points").pluck().get();

test("stores a batch and answers the way Overland expects", async () => {
  const { app, db } = await setup();
  const res = await ingest(app, [
    feature("2026-11-16T10:00:00-0500"),
    feature("2026-11-16T10:00:30-0500"),
  ]);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.json(), { result: "ok" });
  assert.equal(count(db), 2);
  const row = db.prepare("select * from points order by ts limit 1").get() as Record<string, unknown>;
  assert.equal(row.ts, Date.parse("2026-11-16T15:00:00Z"));
  assert.equal(row.lat, 40.7484);
  assert.equal(row.lon, -73.9857);
  assert.equal(row.accuracy, 5);
  assert.equal(row.battery, 0.8);
});

test("a retried batch stores nothing twice", async () => {
  const { app, db } = await setup();
  const batch = [feature("2026-11-16T10:00:00Z"), feature("2026-11-16T10:00:30Z")];
  await ingest(app, batch);
  const res = await ingest(app, batch);
  assert.deepEqual(res.json(), { result: "ok" });
  assert.equal(count(db), 2);
});

test("bad points are skipped without failing the batch", async () => {
  const { app, db } = await setup();
  const res = await ingest(app, [
    feature("2026-11-16T10:00:00Z"),
    feature("not a time"),
    feature("2026-11-16T10:01:00Z", 500, 40), // longitude out of range
    { type: "Feature", geometry: { type: "LineString", coordinates: [] }, properties: {} },
    "garbage",
  ]);
  assert.deepEqual(res.json(), { result: "ok" });
  assert.equal(count(db), 1);
});

test("iOS 'unknown' values (-1) are stored as null", async () => {
  const { app, db } = await setup();
  await ingest(app, [
    feature("2026-11-16T10:00:00Z", -73.98, 40.75, { speed: -1, horizontal_accuracy: -1, battery_level: -1 }),
  ]);
  const row = db.prepare("select speed, accuracy, battery from points").get();
  assert.deepEqual({ ...(row as object) }, { speed: null, accuracy: null, battery: null });
});

test("rejects a missing or wrong token", async () => {
  const { app, db } = await setup();
  const batch = [feature("2026-11-16T10:00:00Z")];
  assert.equal((await ingest(app, batch, {} as typeof auth)).statusCode, 401);
  assert.equal((await ingest(app, batch, { authorization: "Bearer nope" })).statusCode, 401);
  assert.equal(count(db), 0);
});

test("without a configured token, ingest is 503 so Overland retries", async () => {
  const { app } = await setup({});
  const res = await ingest(app, [feature("2026-11-16T10:00:00Z")], {
    authorization: `Bearer ${TOKEN}`,
  });
  assert.equal(res.statusCode, 503);
});

test("a body without locations is a 400", async () => {
  const { app } = await setup();
  const res = await app.inject({ method: "POST", url: "/ingest", headers: auth, payload: { hi: 1 } });
  assert.equal(res.statusCode, 400);
});

test("GET /debug/points returns the newest points, token required", async () => {
  const { app } = await setup();
  await ingest(app, [
    feature("2026-11-16T10:00:00Z"),
    feature("2026-11-16T10:02:00Z"),
    feature("2026-11-16T10:01:00Z"),
  ]);
  assert.equal((await app.inject({ url: "/debug/points" })).statusCode, 401);
  const res = await app.inject({ url: "/debug/points?last=2", headers: auth });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(
    res.json().map((p: { at: string }) => p.at),
    ["2026-11-16T10:02:00.000Z", "2026-11-16T10:01:00.000Z"],
  );
});
