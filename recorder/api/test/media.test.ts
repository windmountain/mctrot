// Runs the real vips and ffmpeg (on PATH: `nix develop` and the Nix build
// provide them) on real files.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { isHeif, mediaKind, processMedia } from "../src/media.ts";

const tmp = () => mkdtempSync(join(tmpdir(), "mctrot-media-"));
const fixture = (name: string) => new URL(`./fixtures/${name}`, import.meta.url).pathname;
const ffmpeg = (...args: string[]) => execFileSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", ...args]);
const header = (file: string, field: string) =>
  execFileSync("vipsheader", ["-f", field, file]).toString().trim();

test("HEIF is recognised by its signature", () => {
  assert.equal(isHeif(fixture("tiled.heic")), true);
  const dir = tmp();
  const jpg = join(dir, "x.jpg");
  ffmpeg("-f", "lavfi", "-i", "testsrc2=size=64x64:duration=1", "-frames:v", "1", jpg);
  assert.equal(isHeif(jpg), false);
});

test("content types map to post kinds", () => {
  assert.equal(mediaKind("image/heic"), "photo");
  assert.equal(mediaKind("video/quicktime"), "video");
  assert.equal(mediaKind("audio/x-m4a"), "voice");
  assert.equal(mediaKind("application/pdf"), null);
});

test("an iPhone-style tiled HEIC becomes a full-size JPEG and a thumbnail", async () => {
  const media = tmp();
  const out = await processMedia("photo", fixture("tiled.heic"), media, "p1");
  assert.equal(out.mediaPath, "p1/full.jpg");
  assert.equal(out.thumbPath, "p1/thumb.jpg");
  // 2048x2560 shrunk to fit 1600 on its long side; the thumb to 400.
  assert.deepEqual([out.width, out.height], [1280, 1600]);
  assert.equal(header(join(media, "p1/thumb.jpg"), "height"), "400");
  assert.equal(header(join(media, "p1/full.jpg"), "vips-loader"), "jpegload");
});

test("photos lose their metadata (EXIF holds where they were taken)", async () => {
  const dir = tmp();
  const input = join(dir, "in.jpg");
  // A JPEG with EXIF: vips writes the source HEIC's EXIF block back out.
  execFileSync("vips", ["copy", `${fixture("tiled.heic")}[unlimited]`, input]);
  const out = await processMedia("photo", input, dir, "p2");
  assert.throws(() => header(join(dir, out.mediaPath), "exif-data"));
});

test("a small photo isn't enlarged", async () => {
  const dir = tmp();
  const input = join(dir, "small.jpg");
  ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x240:duration=1", "-frames:v", "1", input);
  const out = await processMedia("photo", input, dir, "p3");
  assert.deepEqual([out.width, out.height], [320, 240]);
});

test("portrait video: 720p H.264, playable while loading, with a poster", async () => {
  const dir = tmp();
  const input = join(dir, "clip.mov");
  ffmpeg(
    "-f", "lavfi", "-i", "testsrc2=size=1080x1920:rate=30:duration=2",
    "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
    "-c:v", "libx264", "-c:a", "aac", "-shortest", input,
  );
  const out = await processMedia("video", input, dir, "v1");
  assert.deepEqual([out.width, out.height], [720, 1280]);
  assert.ok(out.durationMs! > 1900 && out.durationMs! < 2200, String(out.durationMs));
  assert.ok(existsSync(join(dir, "v1/poster.jpg")));
  // faststart: the index ("moov") comes before the media data ("mdat").
  const bytes = readFileSync(join(dir, out.mediaPath)).toString("latin1");
  assert.ok(bytes.indexOf("moov") < bytes.indexOf("mdat"));
});

test("small video isn't enlarged", async () => {
  const dir = tmp();
  const input = join(dir, "small.mp4");
  ffmpeg("-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=1", "-c:v", "libx264", input);
  const out = await processMedia("video", input, dir, "v2");
  assert.deepEqual([out.width, out.height], [640, 360]);
});

test("a voice note becomes AAC .m4a", async () => {
  const dir = tmp();
  const input = join(dir, "memo.wav");
  ffmpeg("-f", "lavfi", "-i", "sine=frequency=300:duration=3", input);
  const out = await processMedia("voice", input, dir, "a1");
  assert.equal(out.mediaPath, "a1/voice.m4a");
  assert.ok(out.durationMs! > 2900 && out.durationMs! < 3200, String(out.durationMs));
});

test("a broken file fails with a reason and leaves nothing behind", async () => {
  const dir = tmp();
  const input = join(dir, "broken.jpg");
  writeFileSync(input, "not really a jpeg");
  await assert.rejects(processMedia("photo", input, dir, "bad"), (err: Error) => err.message.length > 0);
  assert.equal(existsSync(join(dir, "bad")), false);
});
