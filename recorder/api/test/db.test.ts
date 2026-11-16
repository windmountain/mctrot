import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import Database from "better-sqlite3";
import { openDb } from "../src/db.ts";
import { SCHEMA_VERSION } from "../src/schema.ts";

function fileWithOldSchema() {
  const dir = mkdtempSync(join(tmpdir(), "mctrot-db-"));
  const path = join(dir, "recorder.sqlite");
  const old = new Database(path);
  old.exec("create table points (ts integer primary key, lat real)");
  old.exec("insert into points values (1, 2)");
  old.pragma(`user_version = ${SCHEMA_VERSION - 1}`);
  old.close();
  return { dir, path };
}

test("a new file gets the current schema", () => {
  const dir = mkdtempSync(join(tmpdir(), "mctrot-db-"));
  const { db, archived } = openDb(join(dir, "recorder.sqlite"));
  assert.equal(db.pragma("user_version", { simple: true }), SCHEMA_VERSION);
  assert.equal(archived, undefined);
});

test("reopening the same schema keeps the data", () => {
  const dir = mkdtempSync(join(tmpdir(), "mctrot-db-"));
  const path = join(dir, "recorder.sqlite");
  const first = openDb(path).db;
  first.prepare("insert into points (ts, lat, lon, received_at) values (1, 2, 3, 4)").run();
  first.close();
  const { db, archived } = openDb(path);
  assert.equal(archived, undefined);
  assert.equal(db.prepare("select count(*) from points").pluck().get(), 1);
});

test("a schema change moves the old file aside and starts empty", () => {
  const { dir, path } = fileWithOldSchema();
  const { db, archived } = openDb(path, "reset");
  assert.ok(archived && existsSync(archived));
  assert.equal(db.pragma("user_version", { simple: true }), SCHEMA_VERSION);
  assert.equal(db.prepare("select count(*) from points").pluck().get(), 0);
  assert.equal(readdirSync(dir).filter((f) => f.endsWith(".bak")).length, 1);
});

test("with MCTROT_DB_RESET=never, a schema change refuses to start", () => {
  const { dir, path } = fileWithOldSchema();
  assert.throws(() => openDb(path, "never"), /Refusing to start/);
  assert.equal(readdirSync(dir).filter((f) => f.endsWith(".bak")).length, 0);
  const old = new Database(path);
  assert.equal(old.prepare("select count(*) from points").pluck().get(), 1);
});
