// A real tus upload (the official tus client) through the API, then the
// worker's processing, then the post in /live.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import * as tus from "tus-js-client";
import { MAX_ATTEMPTS, processNext, queueUpload, requeueAbandoned } from "../src/jobs.ts";
import { auth, setup } from "./helpers.ts";

const photo = () => {
  const dir = mkdtempSync(join(tmpdir(), "mctrot-up-"));
  const file = join(dir, "photo.jpg");
  execFileSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
    "testsrc2=size=800x600:duration=1", "-frames:v", "1", file]);
  return readFileSync(file);
};

function upload(endpoint: string, data: Buffer, metadata: Record<string, string>, headers: Record<string, string> = auth) {
  return new Promise<void>((resolve, reject) => {
    new tus.Upload(data, {
      endpoint,
      metadata,
      headers,
      retryDelays: [],
      chunkSize: 16 * 1024, // several PATCHes, as on a phone
      onSuccess: () => resolve(),
      onError: reject,
    }).start();
  });
}

async function listen() {
  const s = await setup();
  await s.app.listen({ port: 0, host: "127.0.0.1" });
  const address = s.app.server.address() as { port: number };
  return { ...s, endpoint: `http://127.0.0.1:${address.port}/uploads` };
}

test("upload a photo: processing, then ready in /live with its URLs", async (t) => {
  const { app, db, endpoint } = await listen();
  t.after(() => app.close());
  const ts = Date.parse("2026-12-05T13:00:00Z");
  await upload(endpoint, photo(), { postId: "photo-1", ts: String(ts), filetype: "image/jpeg", filename: "p.jpg" });

  const status = await app.inject({ url: "/posts/status?ids=photo-1,nope", headers: auth });
  assert.deepEqual(status.json(), {
    "photo-1": { status: "processing", error: null },
    nope: { status: "missing", error: null },
  });
  // Not in /live until processed.
  assert.equal((await app.inject({ url: "/live" })).json().posts.length, 0);

  const mediaDir = mkdtempSync(join(tmpdir(), "mctrot-media-"));
  const job = db.prepare("select upload_path from jobs").pluck().get() as string;
  assert.ok(existsSync(job));
  assert.equal(await processNext(db, mediaDir), true);
  assert.equal(existsSync(job), false, "the upload is removed once processed");
  assert.equal(await processNext(db, mediaDir), false, "nothing left to do");

  const post = (await app.inject({ url: "/live" })).json().posts[0];
  assert.equal(post.type, "photo");
  assert.equal(post.ts, ts);
  assert.equal(post.media.url, "https://media.example.test/photo-1/full.jpg");
  assert.equal(post.media.thumbUrl, "https://media.example.test/photo-1/thumb.jpg");
  assert.deepEqual([post.media.width, post.media.height], [800, 600]);
  assert.ok(existsSync(join(mediaDir, "photo-1/full.jpg")));
});

test("uploads need the token or a session", async (t) => {
  const { app, endpoint } = await listen();
  t.after(() => app.close());
  await assert.rejects(
    upload(endpoint, photo(), { postId: "x", ts: "1", filetype: "image/jpeg" }, {}),
    /401/,
  );
});

test("uploads of other kinds of file are refused up front", async (t) => {
  const { app, endpoint } = await listen();
  t.after(() => app.close());
  await assert.rejects(
    upload(endpoint, Buffer.from("%PDF-1.4"), { postId: "doc", ts: "1", filetype: "application/pdf" }),
    /400/,
  );
});

test("the same post uploaded twice is one post and one job", async () => {
  const { db } = await setup();
  const post = { id: "p", ts: 1, kind: "photo" as const };
  assert.equal(queueUpload(db, post, { path: "/tmp/a", contentType: "image/jpeg" }), true);
  assert.equal(queueUpload(db, post, { path: "/tmp/b", contentType: "image/jpeg" }), false);
  assert.equal(db.prepare("select count(*) from jobs").pluck().get(), 1);
});

test("a job that keeps failing marks its post failed, with the reason", async () => {
  const { db } = await setup();
  queueUpload(db, { id: "p", ts: 1, kind: "photo" }, { path: "/nonexistent/file", contentType: "image/jpeg" });
  const media = mkdtempSync(join(tmpdir(), "mctrot-media-"));
  for (let i = 0; i < MAX_ATTEMPTS; i++) assert.equal(await processNext(db, media), true);
  const post = db.prepare("select status, error from posts where id = 'p'").get() as { status: string; error: string };
  assert.equal(post.status, "failed");
  assert.ok(post.error.length > 0);
  assert.equal(await processNext(db, media), false, "failed jobs aren't retried forever");
});

test("a job left running by a crashed worker goes back in the queue", async () => {
  const { db } = await setup();
  queueUpload(db, { id: "p", ts: 1, kind: "photo" }, { path: "/x", contentType: "image/jpeg" });
  db.prepare("update jobs set status = 'running'").run();
  assert.equal(requeueAbandoned(db), 1);
  assert.equal(db.prepare("select status from jobs").pluck().get(), "queued");
});
