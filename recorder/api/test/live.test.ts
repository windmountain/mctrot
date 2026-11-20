import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { buildApp } from "../src/app.ts";
import { openDb } from "../src/db.ts";
import { LiveResponse, liveJsonSchema } from "../src/live.ts";
import { SITE, auth, feature, setup } from "./helpers.ts";

test("GET /live before any points: position is null", async () => {
  const { app } = await setup();
  const res = await app.inject({ url: "/live" });
  assert.equal(res.statusCode, 200);
  assert.equal(res.json().position, null);
  assert.ok(Number.isInteger(res.json().serverTs));
});

test("GET /live returns the latest point, without a token, readable cross-origin", async () => {
  const { app } = await setup();
  await app.inject({
    method: "POST",
    url: "/ingest",
    headers: auth,
    payload: {
      locations: [
        feature("2026-11-16T10:00:00Z", -73.99, 40.73),
        feature("2026-11-16T10:01:00Z", -73.98, 40.74),
      ],
    },
  });
  const res = await app.inject({ url: "/live" });
  assert.equal(res.headers["access-control-allow-origin"], "*");
  assert.equal(res.headers["cache-control"], "no-store");
  const body = res.json();
  assert.deepEqual(body.position, {
    ts: Date.parse("2026-11-16T10:01:00Z"),
    lat: 40.74,
    lon: -73.98,
    accuracy: 5,
  });
  assert.ok(LiveResponse.safeParse(body).success, "response matches the contract");
});

test("live.schema.json is up to date (npm run schema)", () => {
  const onDisk = JSON.parse(readFileSync(new URL("../live.schema.json", import.meta.url), "utf8"));
  assert.deepEqual(onDisk, liveJsonSchema());
});

test("GET /live without a route plan: no stores", async () => {
  const { buildApp } = await import("../src/app.ts");
  const { openDb } = await import("../src/db.ts");
  const { NO_PLAN } = await import("../src/plan.ts");
  const app = await buildApp({
    db: openDb(":memory:").db,
    plan: NO_PLAN,
    version: "x",
    startedAt: new Date(),
    ingestToken: "t",
    sessionSecret: undefined,
    origin: "http://localhost",
    rpID: "localhost",
    postDir: ".",
    uploadDir: (await import("node:os")).tmpdir(),
    mediaUrl: "http://localhost/media",
    mediaDir: (await import("node:os")).tmpdir(),
    guests: { siteOrigin: SITE, mailer: async () => {} },
  });
  const body = (await app.inject({ url: "/live" })).json();
  assert.deepEqual(body.stores, []);
  assert.ok(LiveResponse.safeParse(body).success);
});

test("GET /live lists stores with only the contract's fields", async () => {
  const { app } = await setup();
  const body = (await app.inject({ url: "/live" })).json();
  assert.deepEqual(Object.keys(body.stores[0]).sort(), ["address", "arrive", "depart", "id", "lat", "lon", "name"]);
});

test("GET /live has the plan: stores in order with planned times, and the planned route", async () => {
  const plan = {
    stores: [
      { id: "40", name: "SLOPER", address: "608 West 207th Street", lat: 40.8674, lon: -73.9213, arrive: "2026-11-21T10:05:00Z", depart: "2026-11-21T10:09:00Z" },
      { id: "36", name: "STRADDLER", address: "208 Dyckman St", lat: 40.8651, lon: -73.9272, arrive: "2026-11-21T10:14:00Z", depart: "2026-11-21T10:18:00Z" },
    ],
    track: [[40.8674, -73.9213], [40.866, -73.924], [40.8651, -73.9272]] as [number, number][],
  };
  const app = await buildApp({
    db: openDb(":memory:").db,
    plan,
    version: "x",
    startedAt: new Date(),
    ingestToken: "t",
    sessionSecret: undefined,
    origin: "http://localhost",
    rpID: "localhost",
    postDir: ".",
    uploadDir: (await import("node:os")).tmpdir(),
    mediaUrl: "http://localhost/media",
    mediaDir: (await import("node:os")).tmpdir(),
    guests: { siteOrigin: SITE, mailer: async () => {} },
  });
  const body = (await app.inject({ url: "/live" })).json();
  assert.deepEqual(body.stores.map((s: { name: string }) => s.name), ["SLOPER", "STRADDLER"]);
  assert.equal(body.stores[0].arrive, Date.parse("2026-11-21T10:05:00Z"));
  assert.equal(body.stores[1].depart, Date.parse("2026-11-21T10:18:00Z"));
  assert.deepEqual(body.plannedTrack, plan.track);
  assert.ok(LiveResponse.safeParse(body).success);
});
