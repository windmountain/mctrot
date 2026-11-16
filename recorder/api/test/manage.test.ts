// Deleting and editing from the upload page.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { processNext, queueUpload } from "../src/jobs.ts";
import { auth, ORIGIN, setup, TOKEN } from "./helpers.ts";

const text = (id: string, t = "hi", ts = Date.now()) => ({ id, ts, type: "text", text: t });

test("/sent lists check-ins and posts newest first, with any status", async () => {
  const { app, db } = await setup();
  await app.inject({ method: "POST", url: "/visits", headers: auth, payload: { id: "c1", ts: 1000 } });
  await app.inject({ method: "POST", url: "/posts", headers: auth, payload: text("p1", "hello", 2000) });
  queueUpload(db, { id: "u1", ts: 3000, kind: "photo" }, { path: "/tmp/nothing", contentType: "image/jpeg" });
  const { items } = (await app.inject({ url: "/sent", headers: auth })).json();
  assert.deepEqual(
    items.map((i: { kind: string; id: string }) => `${i.kind}:${i.id}`),
    ["post:u1", "post:p1", "checkin:c1"],
  );
  assert.equal(items[0].status, "processing");
  assert.equal(items[1].text, "hello");
});

test("/sent, deleting and editing need sign-in", async () => {
  const { app } = await setup();
  assert.equal((await app.inject({ url: "/sent" })).statusCode, 401);
  assert.equal((await app.inject({ method: "DELETE", url: "/visits/x" })).statusCode, 401);
  assert.equal((await app.inject({ method: "DELETE", url: "/posts/x" })).statusCode, 401);
  assert.equal((await app.inject({ method: "PATCH", url: "/posts/x", payload: { text: "y" } })).statusCode, 401);
});

test("a check-in is deleted for good, and leaves /live", async () => {
  const { app } = await setup();
  await app.inject({ method: "POST", url: "/attempts/start", headers: auth });
  await app.inject({ method: "POST", url: "/visits", headers: auth, payload: { id: "c1" } });
  assert.equal((await app.inject({ url: "/live" })).json().visits.length, 1);
  const del = await app.inject({ method: "DELETE", url: "/visits/c1", headers: auth });
  assert.equal(del.statusCode, 200);
  assert.equal((await app.inject({ url: "/live" })).json().visits.length, 0);
  assert.equal((await app.inject({ method: "DELETE", url: "/visits/c1", headers: auth })).statusCode, 404);
});

test("a text post can be edited, and the edit shows in /live", async () => {
  const { app } = await setup();
  await app.inject({ method: "POST", url: "/posts", headers: auth, payload: text("p1", "helo") });
  const res = await app.inject({ method: "PATCH", url: "/posts/p1", headers: auth, payload: { text: " hello " } });
  assert.equal(res.statusCode, 200);
  assert.equal((await app.inject({ url: "/live" })).json().posts[0].text, "hello");
  assert.equal((await app.inject({ method: "PATCH", url: "/posts/p1", headers: auth, payload: { text: "  " } })).statusCode, 400);
  assert.equal((await app.inject({ method: "PATCH", url: "/posts/nope", headers: auth, payload: { text: "x" } })).statusCode, 404);
});

test("a media post can't be edited", async () => {
  const { app, db } = await setup();
  queueUpload(db, { id: "u1", ts: 1, kind: "photo" }, { path: "/tmp/nothing", contentType: "image/jpeg" });
  const res = await app.inject({ method: "PATCH", url: "/posts/u1", headers: auth, payload: { text: "x" } });
  assert.equal(res.statusCode, 400);
});

test("deleting a media post removes its row, job, upload and files", async () => {
  const { app, db, mediaDir } = await setup();
  const upload = join(mediaDir, "..", `upload-${process.pid}-${Date.now()}`);
  writeFileSync(upload, "x");
  writeFileSync(`${upload}.json`, "{}");
  queueUpload(db, { id: "u1", ts: 1, kind: "photo" }, { path: upload, contentType: "image/jpeg" });
  mkdirSync(join(mediaDir, "u1"));
  writeFileSync(join(mediaDir, "u1", "full.jpg"), "x");
  const res = await app.inject({ method: "DELETE", url: "/posts/u1", headers: auth });
  assert.equal(res.statusCode, 200);
  assert.equal(db.prepare("select count(*) from posts").pluck().get(), 0);
  assert.equal(db.prepare("select count(*) from jobs").pluck().get(), 0);
  assert.equal(existsSync(upload), false);
  assert.equal(existsSync(`${upload}.json`), false);
  assert.equal(existsSync(join(mediaDir, "u1")), false);
  assert.equal(await processNext(db, mediaDir), false, "no job left for the worker");
});

test("a post deleted while the worker processes it leaves no files behind", async () => {
  const { app, db, mediaDir } = await setup();
  const voice = join(mediaDir, "..", `voice-${process.pid}-${Date.now()}.m4a`);
  execFileSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
    "sine=frequency=440:duration=1", "-c:a", "aac", voice]);
  queueUpload(db, { id: "u1", ts: 1, kind: "voice" }, { path: voice, contentType: "audio/mp4" });
  // processNext claims the job before its first await; delete during ffmpeg.
  const working = processNext(db, mediaDir);
  assert.equal((await app.inject({ method: "DELETE", url: "/posts/u1", headers: auth })).statusCode, 200);
  assert.equal(await working, true);
  assert.equal(db.prepare("select count(*) from posts").pluck().get(), 0);
  assert.equal(existsSync(join(mediaDir, "u1")), false);
});

test("a post id can't name a folder outside the media folder", async () => {
  const { app, mediaDir } = await setup();
  mkdirSync(join(mediaDir, "keep"));
  await app.inject({ method: "POST", url: "/posts", headers: auth, payload: text("../keep") });
  const res = await app.inject({ method: "DELETE", url: `/posts/${encodeURIComponent("../keep")}`, headers: auth });
  assert.equal(res.statusCode, 200);
  assert.ok(existsSync(join(mediaDir, "keep")));
});

test("the page deletes with its session cookie", async () => {
  const { app } = await setup();
  const signIn = await app.inject({ method: "POST", url: "/auth/token", payload: { token: TOKEN } });
  const cookie = String(signIn.headers["set-cookie"]).split(";")[0]!;
  await app.inject({ method: "POST", url: "/visits", headers: auth, payload: { id: "c1" } });
  const res = await app.inject({ method: "DELETE", url: "/visits/c1", headers: { cookie, origin: ORIGIN } });
  assert.equal(res.statusCode, 200);
  const evil = await app.inject({ method: "DELETE", url: "/visits/c1", headers: { cookie, origin: "https://evil.example" } });
  assert.equal(evil.statusCode, 401);
});
