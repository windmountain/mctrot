import assert from "node:assert/strict";
import { test } from "node:test";
import { setup } from "./helpers.ts";

test("GET /health reports version, uptime, database and secrets", async () => {
  const { app } = await setup();
  const res = await app.inject({ method: "GET", url: "/health" });
  assert.equal(res.statusCode, 200);
  const body = res.json();
  assert.equal(body.version, "abc1234");
  assert.ok(body.uptimeSeconds >= 5);
  assert.equal(body.database.ok, true);
  assert.equal(body.database.schemaVersion, 4);
  assert.match(body.database.sqlite, /^3\./);
  assert.deepEqual(body.secrets, { ingestToken: true, sessionSecret: true });
});

test("GET /health is 503 when the database is unusable", async () => {
  const { db, app } = await setup();
  db.close();
  const res = await app.inject({ method: "GET", url: "/health" });
  assert.equal(res.statusCode, 503);
  assert.equal(res.json().database.ok, false);
});

test("GET / still says hello", async () => {
  const { app } = await setup();
  const res = await app.inject({ method: "GET", url: "/" });
  assert.equal(res.body, "hello from mctrot\n");
});
