// Resumable uploads (tus, https://tus.io) at /uploads, for the upload
// page's photos, videos and voice notes: a video that drops at 70% resumes
// at 70%. A finished upload becomes a "processing" post and a job for the
// worker (src/jobs.ts).
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { FileStore } from "@tus/file-store";
import { Server } from "@tus/server";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { Db } from "./db.ts";
import { queueUpload } from "./jobs.ts";
import { mediaKind } from "./media.ts";
import { letterFromFilename } from "./pairs.ts";

// Big enough for a few minutes of 1080p30 video; the page warns sooner.
export const MAX_UPLOAD_BYTES = 1024 ** 3; // 1 GiB

// Each upload says which post it is and when it was made, as tus metadata.
// The filename only matters for DoubleTake's _A/_B (src/pairs.ts); it isn't kept.
type Meta = { postId: string; ts: number; contentType: string; filename: string | null };

function readMeta(metadata: Record<string, string | null> | undefined): Meta | string {
  const postId = metadata?.postId ?? "";
  const contentType = metadata?.filetype ?? "";
  const ts = Number(metadata?.ts);
  if (!/^[A-Za-z0-9-]{1,100}$/.test(postId)) return "missing or bad postId";
  if (!Number.isInteger(ts) || ts <= 0) return "missing or bad ts";
  if (!mediaKind(contentType)) return `can't post a ${contentType || "file of unknown type"}`;
  return { postId, ts, contentType, filename: metadata?.filename ?? null };
}

export function registerUploads(
  app: FastifyInstance,
  db: Db,
  uploadDir: string,
  allowed: (req: FastifyRequest, reply: FastifyReply) => boolean,
) {
  mkdirSync(uploadDir, { recursive: true });
  const tus = new Server({
    path: "/uploads",
    datastore: new FileStore({ directory: uploadDir }),
    maxSize: MAX_UPLOAD_BYTES,
    // Behind Caddy: build upload URLs from X-Forwarded-Proto/Host (https).
    respectForwardedHeaders: true,
    async onUploadCreate(_req, upload) {
      const meta = readMeta(upload.metadata);
      if (typeof meta === "string") throw { status_code: 400, body: meta };
      return {};
    },
    async onUploadFinish(_req, upload) {
      const meta = readMeta(upload.metadata);
      if (typeof meta === "string") throw { status_code: 400, body: meta };
      queueUpload(
        db,
        { id: meta.postId, ts: meta.ts, kind: mediaKind(meta.contentType)!, letter: letterFromFilename(meta.filename) },
        { path: join(uploadDir, upload.id), contentType: meta.contentType },
      );
      return {};
    },
  });

  // tus reads the request body itself: let PATCH bodies through unparsed.
  app.addContentTypeParser("application/offset+octet-stream", (_req, _payload, done) => done(null));

  const handle = async (req: FastifyRequest, reply: FastifyReply) => {
    if (!allowed(req, reply)) return reply;
    reply.hijack();
    await tus.handle(req.raw, reply.raw);
  };
  app.route({ method: ["POST", "PATCH", "HEAD", "OPTIONS", "DELETE"], url: "/uploads", handler: handle });
  app.route({ method: ["POST", "PATCH", "HEAD", "OPTIONS", "DELETE"], url: "/uploads/*", handler: handle });
}
