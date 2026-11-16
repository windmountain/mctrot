// Turns an uploaded file into what /live shows, with the `vips` and
// `ffmpeg` command-line tools (on PATH; host/api.nix puts them there).
// Command-line tools rather than native Node modules, which fight Nix's
// sandboxed builds. Everything strips metadata: a phone photo's EXIF holds
// exactly where it was taken.
import { execFile } from "node:child_process";
import { closeSync, mkdirSync, openSync, readSync, rmSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

export type MediaKind = "photo" | "video" | "voice";

// What kind of post an upload's content type makes; null if it's none.
export function mediaKind(contentType: string): MediaKind | null {
  if (contentType.startsWith("image/")) return "photo";
  if (contentType.startsWith("video/")) return "video";
  if (contentType.startsWith("audio/")) return "voice";
  return null;
}

// Paths are relative to the media folder: "<post id>/full.jpg".
export type Processed = {
  mediaPath: string;
  thumbPath: string | null;
  posterPath: string | null;
  width: number | null;
  height: number | null;
  durationMs: number | null;
};

export const PHOTO_FULL = 1600; // longest side, px
export const PHOTO_THUMB = 400;
export const VIDEO_SHORT_SIDE = 720;

// Makes <mediaDir>/<postId>/ and its files from `input`. On failure, leaves
// nothing behind and throws an error saying what went wrong.
export async function processMedia(
  kind: MediaKind,
  input: string,
  mediaDir: string,
  postId: string,
): Promise<Processed> {
  const dir = join(mediaDir, postId);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  try {
    if (kind === "photo") return await photo(input, dir, postId);
    if (kind === "video") return await video(input, dir, postId);
    return await voice(input, dir, postId);
  } catch (err) {
    rmSync(dir, { recursive: true, force: true });
    throw new Error(describe(err));
  }
}

function describe(err: unknown): string {
  const e = err as { stderr?: string; message?: string };
  const detail = (e.stderr ?? "").trim().split("\n").filter(Boolean).slice(-2).join(" ");
  return detail || e.message || String(err);
}

async function photo(input: string, dir: string, postId: string): Promise<Processed> {
  // iPhone HEIC photos are grids of ~48 tiles; libheif refuses more than 16
  // by default, even to read the header. These are my own uploads, so lift
  // that limit for HEIF.
  const source = isHeif(input) ? `${input}[unlimited]` : input;
  // thumbnail: rotates upright from EXIF, shrinks (never enlarges) to fit,
  // and keep=none drops all metadata.
  const save = (name: string, size: number) =>
    run("vips", ["thumbnail", source, join(dir, `${name}[Q=82,keep=none]`), String(size), "--size", "down"]);
  await save("full.jpg", PHOTO_FULL);
  await save("thumb.jpg", PHOTO_THUMB);
  const width = Number((await run("vipsheader", ["-f", "width", join(dir, "full.jpg")])).stdout);
  const height = Number((await run("vipsheader", ["-f", "height", join(dir, "full.jpg")])).stdout);
  return {
    mediaPath: `${postId}/full.jpg`,
    thumbPath: `${postId}/thumb.jpg`,
    posterPath: null,
    width,
    height,
    durationMs: null,
  };
}

// HEIF (HEIC, AVIF) by its signature: an "ftyp" box with a HEIF brand.
const HEIF_BRANDS = new Set(["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1", "avif", "avis"]);
export function isHeif(file: string): boolean {
  const head = Buffer.alloc(12);
  const fd = openSync(file, "r");
  try {
    readSync(fd, head, 0, 12, 0);
  } finally {
    closeSync(fd);
  }
  return head.toString("latin1", 4, 8) === "ftyp" && HEIF_BRANDS.has(head.toString("latin1", 8, 12));
}

type Probe = { streams?: { codec_type?: string; width?: number; height?: number }[]; format?: { duration?: string } };

async function probe(file: string): Promise<Probe> {
  const { stdout } = await run("ffprobe", [
    "-v", "error", "-show_entries", "stream=codec_type,width,height:format=duration", "-of", "json", file,
  ]);
  return JSON.parse(stdout) as Probe;
}

const durationMs = (p: Probe) => {
  const s = Number(p.format?.duration);
  return Number.isFinite(s) ? Math.round(s * 1000) : null;
};

async function video(input: string, dir: string, postId: string): Promise<Processed> {
  const out = join(dir, "video.mp4");
  // 720p by its short side (portrait stays portrait), never enlarged; even
  // dimensions for H.264. ffmpeg turns phone video upright on its own.
  const scale =
    `scale=w='if(gt(iw,ih),-2,min(${VIDEO_SHORT_SIDE},iw))':` +
    `h='if(gt(iw,ih),min(${VIDEO_SHORT_SIDE},ih),-2)'`;
  await run("ffmpeg", [
    "-y", "-v", "error", "-i", input,
    "-map_metadata", "-1", "-vf", scale,
    "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
    "-c:a", "aac", "-b:a", "128k",
    // The index up front, so playback starts before the whole file arrives.
    "-movflags", "+faststart",
    out,
  ]);
  const p = await probe(out);
  const ms = durationMs(p);
  // The poster: a frame half a second in, or the first for shorter clips.
  const at = ms !== null && ms > 1000 ? "0.5" : "0";
  await run("ffmpeg", ["-y", "-v", "error", "-ss", at, "-i", out, "-frames:v", "1", "-q:v", "3", join(dir, "poster.jpg")]);
  const v = p.streams?.find((s) => s.codec_type === "video");
  return {
    mediaPath: `${postId}/video.mp4`,
    thumbPath: null,
    posterPath: `${postId}/poster.jpg`,
    width: v?.width ?? null,
    height: v?.height ?? null,
    durationMs: ms,
  };
}

async function voice(input: string, dir: string, postId: string): Promise<Processed> {
  const out = join(dir, "voice.m4a");
  await run("ffmpeg", [
    "-y", "-v", "error", "-i", input,
    "-vn", "-map_metadata", "-1", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart",
    out,
  ]);
  return {
    mediaPath: `${postId}/voice.m4a`,
    thumbPath: null,
    posterPath: null,
    width: null,
    height: null,
    durationMs: durationMs(await probe(out)),
  };
}
