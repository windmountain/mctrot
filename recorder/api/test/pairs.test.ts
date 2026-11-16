// DoubleTake pairs: two clips with the same time and length, uploaded
// separately, become one post with an AB and a BA cut.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { processNext, queueUpload } from "../src/jobs.ts";
import { letterFromFilename, PAIR_WAIT_MS } from "../src/pairs.ts";
import { auth, setup } from "./helpers.ts";

// A short clip: a solid colour (so the cut can be checked by colour) with
// a tone, portrait like DoubleTake's.
function clip(color: string, seconds = 2): string {
  const dir = mkdtempSync(join(tmpdir(), "mctrot-dt-"));
  const file = join(dir, "clip.mov");
  execFileSync("ffmpeg", [
    "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", `color=c=${color}:size=360x640:rate=24:duration=${seconds}`,
    "-f", "lavfi", "-i", `sine=frequency=440:duration=${seconds}`,
    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", file,
  ]);
  return file;
}

// The average colour of a frame at `at` seconds, as "r,g,b".
function colourAt(video: string, at: number): [number, number, number] {
  const raw = execFileSync("ffmpeg", [
    "-v", "error", "-ss", String(at), "-i", video, "-frames:v", "1",
    "-vf", "scale=1:1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
  ]);
  return [raw[0]!, raw[1]!, raw[2]!];
}
const isRed = ([r, g, b]: number[]) => r! > 180 && g! < 80 && b! < 80;
const isBlue = ([r, g, b]: number[]) => b! > 180 && r! < 80 && g! < 80;

const TS = Date.parse("2026-11-21T15:00:00Z");

async function drain(db: Parameters<typeof processNext>[0], mediaDir: string) {
  while (await processNext(db, mediaDir));
}

test("the letter comes from DoubleTake's filename, nothing else", () => {
  assert.equal(letterFromFilename("11162026_121306_A.MOV"), "A");
  assert.equal(letterFromFilename("11162026_121306_B.mov"), "B");
  assert.equal(letterFromFilename("IMG_1234.MOV"), null);
  assert.equal(letterFromFilename("CAB.MOV"), null);
  assert.equal(letterFromFilename(null), null);
});

test("two clips with the same time and length become one pair, AB first, with both cuts", async () => {
  const { app, db, mediaDir } = await setup();
  // B arrives first: the order of upload doesn't matter.
  queueUpload(db, { id: "b", ts: TS, kind: "video", letter: "B" }, { path: clip("blue"), contentType: "video/quicktime" });
  await drain(db, mediaDir);
  assert.equal((await app.inject({ url: "/live" })).json().posts.length, 0, "B waits for its partner");
  queueUpload(db, { id: "a", ts: TS, kind: "video", letter: "A" }, { path: clip("red"), contentType: "video/quicktime" });
  await drain(db, mediaDir);

  const posts = (await app.inject({ url: "/live" })).json().posts;
  assert.equal(posts.length, 1, "one post: the pair, not its clips");
  const [pair] = posts;
  assert.equal(pair.type, "pair");
  assert.equal(pair.ts, TS);
  assert.equal(pair.pair.order, "AB");
  assert.match(pair.pair.a.url, /\/a\/video\.mp4$/);
  assert.match(pair.pair.b.url, /\/b\/video\.mp4$/);
  assert.match(pair.media.url, /\/ab\.mp4$/);

  // AB: A's first half (red), then B's (blue); BA the other way round.
  const dir = join(mediaDir, pair.id);
  assert.ok(isRed(colourAt(join(dir, "ab.mp4"), 0.4)));
  assert.ok(isBlue(colourAt(join(dir, "ab.mp4"), 1.6)));
  assert.ok(isBlue(colourAt(join(dir, "ba.mp4"), 0.4)));
  assert.ok(isRed(colourAt(join(dir, "ba.mp4"), 1.6)));
  assert.ok(Math.abs(pair.media.durationMs - 2000) < 100, `the cut is as long as the clips: ${pair.media.durationMs}`);
  // Sound all the way through.
  const audio = execFileSync("ffprobe", ["-v", "error", "-select_streams", "a", "-show_entries", "stream=codec_name", "-of", "csv=p=0", join(dir, "ab.mp4")]);
  assert.equal(String(audio).trim(), "aac");
});

test("BA is set by editing, and /live then serves the BA cut", async () => {
  const { app, db, mediaDir } = await setup();
  queueUpload(db, { id: "a", ts: TS, kind: "video", letter: "A" }, { path: clip("red"), contentType: "video/mp4" });
  queueUpload(db, { id: "b", ts: TS, kind: "video", letter: "B" }, { path: clip("blue"), contentType: "video/mp4" });
  await drain(db, mediaDir);
  const { items } = (await app.inject({ url: "/sent", headers: auth })).json();
  assert.equal(items.length, 1, "the page lists the pair, not its clips");
  assert.equal(items[0].type, "pair");
  assert.equal(items[0].order, "AB");
  const id = items[0].id;

  const res = await app.inject({ method: "PATCH", url: `/posts/${id}`, headers: auth, payload: { order: "BA" } });
  assert.equal(res.statusCode, 200);
  const post = (await app.inject({ url: "/live" })).json().posts[0];
  assert.equal(post.pair.order, "BA");
  assert.match(post.media.url, /\/ba\.mp4$/);
  assert.match(post.media.posterUrl, /\/ba\.jpg$/);
  assert.match((await app.inject({ url: "/sent", headers: auth })).json().items[0].thumbUrl, /\/ba\.jpg$/);

  const bad = await app.inject({ method: "PATCH", url: `/posts/${id}`, headers: auth, payload: { order: "AA" } });
  assert.equal(bad.statusCode, 400);
  const text = await app.inject({ method: "PATCH", url: `/posts/${id}`, headers: auth, payload: { text: "hi" } });
  assert.equal(text.statusCode, 400, "a pair has no text");
});

test("only a pair has an order to edit", async () => {
  const { app } = await setup();
  await app.inject({ method: "POST", url: "/posts", headers: auth, payload: { id: "t", type: "text", text: "x" } });
  const res = await app.inject({ method: "PATCH", url: "/posts/t", headers: auth, payload: { order: "BA" } });
  assert.equal(res.statusCode, 400);
});

test("deleting a pair deletes both clips and all their files", async () => {
  const { app, db, mediaDir } = await setup();
  queueUpload(db, { id: "a", ts: TS, kind: "video", letter: "A" }, { path: clip("red"), contentType: "video/mp4" });
  queueUpload(db, { id: "b", ts: TS, kind: "video", letter: "B" }, { path: clip("blue"), contentType: "video/mp4" });
  await drain(db, mediaDir);
  const id = (await app.inject({ url: "/live" })).json().posts[0].id;
  assert.equal((await app.inject({ method: "DELETE", url: `/posts/${id}`, headers: auth })).statusCode, 200);
  assert.equal(db.prepare("select count(*) from posts").pluck().get(), 0);
  for (const dir of [id, "a", "b"]) assert.equal(existsSync(join(mediaDir, dir)), false, dir);
});

test("a different length, or a different time, isn't a pair", async () => {
  const { app, db, mediaDir } = await setup();
  const now = Date.now();
  queueUpload(db, { id: "a", ts: TS, kind: "video", letter: "A" }, { path: clip("red", 2), contentType: "video/mp4" }, now - PAIR_WAIT_MS - 1);
  queueUpload(db, { id: "b", ts: TS, kind: "video", letter: "B" }, { path: clip("blue", 3), contentType: "video/mp4" }, now - PAIR_WAIT_MS - 1);
  queueUpload(db, { id: "c", ts: TS + 1000, kind: "video", letter: "B" }, { path: clip("blue", 2), contentType: "video/mp4" }, now - PAIR_WAIT_MS - 1);
  await drain(db, mediaDir);
  const posts = (await app.inject({ url: "/live" })).json().posts;
  assert.deepEqual(posts.map((p: { type: string }) => p.type), ["video", "video", "video"]);
});

test("a DoubleTake clip with no partner shows on its own after the wait", async () => {
  const { app, db, mediaDir } = await setup();
  queueUpload(db, { id: "a", ts: TS, kind: "video", letter: "A" }, { path: clip("red"), contentType: "video/mp4" }, Date.now() - PAIR_WAIT_MS - 1);
  queueUpload(db, { id: "plain", ts: TS + 5000, kind: "video" }, { path: clip("blue"), contentType: "video/mp4" });
  await drain(db, mediaDir);
  const posts = (await app.inject({ url: "/live" })).json().posts;
  assert.deepEqual(posts.map((p: { id: string }) => p.id).sort(), ["a", "plain"], "an ordinary video never waits");
});

test("without the letters, the clip that arrived first is A", async () => {
  const { app, db, mediaDir } = await setup();
  queueUpload(db, { id: "first", ts: TS, kind: "video" }, { path: clip("red"), contentType: "video/mp4" }, Date.now() - 2000);
  queueUpload(db, { id: "second", ts: TS, kind: "video" }, { path: clip("blue"), contentType: "video/mp4" });
  await drain(db, mediaDir);
  const [post] = (await app.inject({ url: "/live" })).json().posts;
  assert.equal(post.type, "pair");
  assert.match(post.pair.a.url, /\/first\//);
});
