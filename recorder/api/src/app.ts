import { readFileSync } from "node:fs";
import { join } from "node:path";
import cookie from "@fastify/cookie";
import Fastify, { type FastifyInstance } from "fastify";
import { z } from "zod";
import { startAttempt, stopAttempt } from "./attempts.ts";
import { requireToken, same } from "./auth.ts";
import { type Db, dbStatus } from "./db.ts";
import { live } from "./live.ts";
import {
  authenticate,
  authenticationOptions,
  passkeyCount,
  registerPasskey,
  registrationOptions,
} from "./passkeys.ts";
import type { RoutePlan } from "./plan.ts";
import { lastPoints, OverlandBatch, storePoints } from "./points.ts";
import { MAX_TEXT, recordTextPost } from "./posts.ts";
import { endSession, hasSession, requireWriter, startSession } from "./session.ts";
import { recordTap } from "./visits.ts";

export type AppDeps = {
  db: Db;
  plan: RoutePlan;
  // Git revision of the deployed flake; changes with every deploy.
  version: string;
  startedAt: Date;
  // Overland's access token. Also signs in the upload page the first time,
  // and lets curl post, tap and start attempts.
  ingestToken: string | undefined;
  // Signs the upload page's session cookie; without it, no sign-in.
  sessionSecret: string | undefined;
  // Where the upload page is served from, and the passkeys' domain.
  origin: string;
  rpID: string;
  // The upload page's files (recorder/post/).
  postDir: string;
  logger?: boolean;
};

// When it happened (ms since epoch or an ISO time; default now), and an id
// from the phone's outbox so a retried upload can't count twice.
const when = z.union([z.number().int(), z.string().refine((s) => !Number.isNaN(Date.parse(s)))]);
const toMs = (t: number | string | undefined) =>
  t === undefined ? Date.now() : typeof t === "number" ? t : Date.parse(t);

const TapBody = z.object({ ts: when.optional(), id: z.string().min(1).max(100).optional() }).optional();

const PostBody = z.object({
  id: z.string().min(1).max(100),
  ts: when.optional(),
  type: z.literal("text"),
  text: z.string().trim().min(1).max(MAX_TEXT),
});

// The upload page's files, and the WebAuthn browser library it loads.
const webauthnBrowser = new URL(
  "../node_modules/@simplewebauthn/browser/dist/bundle/index.umd.min.js",
  import.meta.url,
);
const POST_FILES: Record<string, { file: string | URL; type: string }> = {
  "/post": { file: "index.html", type: "text/html; charset=utf-8" },
  "/post/app.js": { file: "app.js", type: "text/javascript; charset=utf-8" },
  "/post/manifest.webmanifest": { file: "manifest.webmanifest", type: "application/manifest+json" },
  "/post/webauthn.js": { file: webauthnBrowser, type: "text/javascript; charset=utf-8" },
};

export async function buildApp(deps: AppDeps): Promise<FastifyInstance> {
  const { db, plan, ingestToken } = deps;
  const session = { origin: deps.origin };
  const passkeys = { origin: deps.origin, rpID: deps.rpID };
  const app = Fastify({ logger: deps.logger ?? false });
  // Without a session secret, a random one keeps the cookie plugin working,
  // but sign-in refuses anyway (see /auth/token and /auth/login/verify).
  await app.register(cookie, { secret: deps.sessionSecret ?? crypto.randomUUID() });

  const writer = (req: Parameters<typeof requireWriter>[2], reply: Parameters<typeof requireWriter>[3]) =>
    requireWriter(ingestToken, session, req, reply);

  app.get("/", async () => "hello from mctrot\n");

  app.get("/health", async (_req, reply) => {
    const database = dbStatus(db);
    reply.code(database.ok ? 200 : 503);
    return {
      version: deps.version,
      startedAt: deps.startedAt.toISOString(),
      uptimeSeconds: Math.round((Date.now() - deps.startedAt.getTime()) / 1000),
      database,
      stores: plan.stores.length,
      secrets: { ingestToken: ingestToken !== undefined, sessionSecret: deps.sessionSecret !== undefined },
    };
  });

  // Overland's batches. Anything but {"result":"ok"} makes Overland keep
  // the batch and retry, so individual bad points are skipped rather than
  // failing the batch: one odd point must never block the queue.
  app.post("/ingest", async (req, reply) => {
    if (!requireToken(ingestToken, req, reply)) return reply;
    const batch = OverlandBatch.safeParse(req.body);
    if (!batch.success) {
      return reply.code(400).send({ error: "expected {locations: [...]}" });
    }
    const result = storePoints(db, batch.data.locations);
    req.log.info(result, "ingest");
    return { result: "ok" };
  });

  // Starting while one runs returns the running one (a retry is harmless).
  app.post("/attempts/start", async (req, reply) => {
    if (!writer(req, reply)) return reply;
    const { attempt, created } = startAttempt(db);
    reply.code(created ? 201 : 200);
    return attempt;
  });

  app.post("/attempts/stop", async (req, reply) => {
    if (!writer(req, reply)) return reply;
    const stopped = stopAttempt(db);
    if (!stopped) return reply.code(409).send({ error: "no attempt is running" });
    return stopped;
  });

  app.post("/visits", async (req, reply) => {
    if (!writer(req, reply)) return reply;
    const body = TapBody.safeParse(req.body ?? undefined);
    if (!body.success) {
      return reply.code(400).send({ error: "expected {ts?: ms or ISO time, id?: string}" });
    }
    const ts = toMs(body.data?.ts);
    const recorded = recordTap(db, ts, body.data?.id);
    reply.code(recorded ? 201 : 200);
    return { ts, recorded };
  });

  app.post("/posts", async (req, reply) => {
    if (!writer(req, reply)) return reply;
    const body = PostBody.safeParse(req.body);
    if (!body.success) {
      return reply
        .code(400)
        .send({ error: `expected {id, ts?, type: "text", text: 1 to ${MAX_TEXT} characters}` });
    }
    const ts = toMs(body.data.ts);
    const recorded = recordTextPost(db, body.data.id, ts, body.data.text);
    reply.code(recorded ? 201 : 200);
    return { id: body.data.id, ts, recorded };
  });

  // --- Signing in to the upload page --------------------------------------

  app.get("/auth/me", async (req) => ({
    signedIn: hasSession(req),
    passkeys: passkeyCount(db),
    canSignIn: deps.sessionSecret !== undefined,
  }));

  // The first time (or if Face ID fails): the ingest token, typed into the
  // page, starts a session.
  app.post("/auth/token", async (req, reply) => {
    if (deps.sessionSecret === undefined) return reply.code(503).send({ error: "no session secret" });
    const token = (req.body as { token?: unknown } | undefined)?.token;
    if (typeof token !== "string" || ingestToken === undefined || !same(token.trim(), ingestToken)) {
      return reply.code(401).send({ error: "wrong token" });
    }
    startSession(reply, session);
    return { signedIn: true };
  });

  app.post("/auth/register/options", async (req, reply) => {
    if (!writer(req, reply)) return reply;
    return registrationOptions(db, passkeys);
  });

  app.post("/auth/register/verify", async (req, reply) => {
    if (!writer(req, reply)) return reply;
    const body = req.body as { flowId?: unknown; response?: unknown } | undefined;
    const ok = await registerPasskey(db, passkeys, body?.flowId, body?.response as never);
    if (!ok) return reply.code(400).send({ error: "couldn't verify that passkey" });
    return { registered: true, passkeys: passkeyCount(db) };
  });

  app.post("/auth/login/options", async (_req, reply) => {
    if (passkeyCount(db) === 0) return reply.code(409).send({ error: "no passkey registered yet" });
    return authenticationOptions(db, passkeys);
  });

  app.post("/auth/login/verify", async (req, reply) => {
    if (deps.sessionSecret === undefined) return reply.code(503).send({ error: "no session secret" });
    const body = req.body as { flowId?: unknown; response?: unknown } | undefined;
    const ok = await authenticate(db, passkeys, body?.flowId, body?.response as never);
    if (!ok) return reply.code(401).send({ error: "couldn't verify that passkey" });
    startSession(reply, session);
    return { signedIn: true };
  });

  app.post("/auth/signout", async (_req, reply) => {
    endSession(reply);
    return { signedIn: false };
  });

  // --- The upload page ------------------------------------------------------

  for (const [path, { file, type }] of Object.entries(POST_FILES)) {
    app.get(path, async (_req, reply) => {
      const body = readFileSync(typeof file === "string" ? join(deps.postDir, file) : file);
      reply.header("content-type", type);
      reply.header("cache-control", "no-cache");
      // Only this origin's own scripts and requests; no third parties.
      reply.header(
        "content-security-policy",
        "default-src 'self'; img-src 'self' https://mctrot.nyc data:; style-src 'self' 'unsafe-inline'",
      );
      return body;
    });
  }

  // --- Public and debug ------------------------------------------------------

  // The public page's one call (website/live.html, on another origin).
  // Public data, so any origin may read it; never cached, it's live.
  app.get("/live", async (_req, reply) => {
    reply.header("access-control-allow-origin", "*");
    reply.header("cache-control", "no-store");
    return live(db, plan);
  });

  // The latest stored points, newest first. Token-protected: it's my
  // location, whether or not an attempt is running.
  app.get("/debug/points", async (req, reply) => {
    if (!requireToken(ingestToken, req, reply)) return reply;
    const last = Number((req.query as { last?: string }).last ?? 10);
    const n = Number.isInteger(last) ? Math.min(Math.max(last, 1), 1000) : 10;
    return lastPoints(db, n);
  });

  return app;
}
