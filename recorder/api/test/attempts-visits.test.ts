import assert from "node:assert/strict";
import { test } from "node:test";
import { auth, feature, setup } from "./helpers.ts";

const post = (app: Awaited<ReturnType<typeof setup>>["app"], url: string, payload?: object) =>
  app.inject({ method: "POST", url, headers: auth, ...(payload ? { payload } : {}) });

test("attempts: start, start again (same one), stop, stop again (409)", async () => {
  const { app } = await setup();
  const first = await post(app, "/attempts/start");
  assert.equal(first.statusCode, 201);
  const again = await post(app, "/attempts/start");
  assert.equal(again.statusCode, 200);
  assert.equal(again.json().id, first.json().id);
  const stop = await post(app, "/attempts/stop");
  assert.equal(stop.statusCode, 200);
  assert.ok(stop.json().endedAt >= stop.json().startedAt);
  assert.equal((await post(app, "/attempts/stop")).statusCode, 409);
});

test("attempts and visits need the token", async () => {
  const { app } = await setup();
  for (const url of ["/attempts/start", "/attempts/stop", "/visits"]) {
    assert.equal((await app.inject({ method: "POST", url })).statusCode, 401, url);
  }
});

test("a retried tap with the same id is recorded once", async () => {
  const { app, db } = await setup();
  const tap = { ts: "2026-12-05T12:00:00Z", id: "tap-1" };
  assert.equal((await post(app, "/visits", tap)).statusCode, 201);
  const retry = await post(app, "/visits", tap);
  assert.equal(retry.statusCode, 200);
  assert.equal(retry.json().recorded, false);
  assert.equal(db.prepare("select count(*) from visit_taps").pluck().get(), 1);
});

test("a tap without a time is now", async () => {
  const { app } = await setup();
  const before = Date.now();
  const res = await post(app, "/visits");
  assert.ok(res.json().ts >= before && res.json().ts <= Date.now());
});

test("/live: a tap at store A during an attempt counts as a visit to A", async () => {
  const { app } = await setup();
  await post(app, "/attempts/start");
  const now = Date.now();
  const iso = (ms: number) => new Date(ms).toISOString();
  // Walking past store A (40.7359, -73.9911), tapping in the middle.
  await post(app, "/ingest", {
    locations: [
      feature(iso(now - 60_000), -73.9911, 40.7357),
      feature(iso(now + 60_000), -73.9911, 40.7361),
    ],
  });
  await post(app, "/visits", { ts: now });
  const body = (await app.inject({ url: "/live" })).json();
  assert.equal(body.attempt.endedAt, null);
  assert.equal(body.stores.length, 3);
  assert.equal(body.visits.length, 1);
  assert.equal(body.visits[0].status, "matched");
  assert.equal(body.visits[0].storeId, "a");
  assert.ok(body.visits[0].distanceM < 5);
});

test("/live: taps outside the attempt don't count", async () => {
  const { app } = await setup();
  await post(app, "/visits", { ts: Date.now() - 3_600_000 }); // an hour before
  await post(app, "/attempts/start");
  const body = (await app.inject({ url: "/live" })).json();
  assert.deepEqual(body.visits, []);
});

test("/live: no attempt yet means no visits", async () => {
  const { app } = await setup();
  await post(app, "/visits");
  const body = (await app.inject({ url: "/live" })).json();
  assert.equal(body.attempt, null);
  assert.deepEqual(body.visits, []);
});
