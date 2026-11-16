import assert from "node:assert/strict";
import { test } from "node:test";
import { buildApp } from "../src/app.ts";
import { openDb } from "../src/db.ts";

function setup() {
  const db = openDb(":memory:");
  const app = buildApp({
    db,
    version: "abc1234",
    startedAt: new Date(Date.now() - 5000),
    secrets: { ingestToken: true },
  });
  return { db, app };
}

test("GET /health reports version, uptime, database and secrets", async () => {
  const { app } = setup();
  const res = await app.inject({ method: "GET", url: "/health" });
  assert.equal(res.statusCode, 200);
  const body = res.json();
  assert.equal(body.version, "abc1234");
  assert.ok(body.uptimeSeconds >= 5);
  assert.equal(body.database.ok, true);
  assert.match(body.database.sqlite, /^3\./);
  assert.deepEqual(body.secrets, { ingestToken: true });
});

test("GET /health is 503 when the database is unusable", async () => {
  const { db, app } = setup();
  db.close();
  const res = await app.inject({ method: "GET", url: "/health" });
  assert.equal(res.statusCode, 503);
  assert.equal(res.json().database.ok, false);
});

test("GET / still says hello", async () => {
  const { app } = setup();
  const res = await app.inject({ method: "GET", url: "/" });
  assert.equal(res.body, "hello from mctrot\n");
});
