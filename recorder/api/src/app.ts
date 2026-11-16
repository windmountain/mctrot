import Fastify, { type FastifyInstance } from "fastify";
import { z } from "zod";
import { startAttempt, stopAttempt } from "./attempts.ts";
import { requireToken } from "./auth.ts";
import { type Db, dbStatus } from "./db.ts";
import { live } from "./live.ts";
import type { RoutePlan } from "./plan.ts";
import { lastPoints, OverlandBatch, storePoints } from "./points.ts";
import { recordTap } from "./visits.ts";

export type AppDeps = {
  db: Db;
  plan: RoutePlan;
  // Git revision of the deployed flake; changes with every deploy.
  version: string;
  startedAt: Date;
  // Overland's access token. Until the upload page's passkey sign-in
  // (build step 9), it also guards attempts, visits and the debug routes.
  ingestToken: string | undefined;
  logger?: boolean;
};

// A Visit tap: when, as ms since epoch or an ISO time (default: now), and
// an id from the phone so a retried upload can't count twice.
const TapBody = z
  .object({
    ts: z.union([z.number().int(), z.string().refine((s) => !Number.isNaN(Date.parse(s)))]).optional(),
    id: z.string().min(1).max(100).optional(),
  })
  .optional();

export function buildApp(deps: AppDeps): FastifyInstance {
  const { db, plan, ingestToken } = deps;
  const app = Fastify({ logger: deps.logger ?? false });

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
      secrets: { ingestToken: ingestToken !== undefined },
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
    if (!requireToken(ingestToken, req, reply)) return reply;
    const { attempt, created } = startAttempt(db);
    reply.code(created ? 201 : 200);
    return attempt;
  });

  app.post("/attempts/stop", async (req, reply) => {
    if (!requireToken(ingestToken, req, reply)) return reply;
    const stopped = stopAttempt(db);
    if (!stopped) return reply.code(409).send({ error: "no attempt is running" });
    return stopped;
  });

  app.post("/visits", async (req, reply) => {
    if (!requireToken(ingestToken, req, reply)) return reply;
    const body = TapBody.safeParse(req.body ?? undefined);
    if (!body.success) {
      return reply.code(400).send({ error: "expected {ts?: ms or ISO time, id?: string}" });
    }
    const raw = body.data?.ts;
    const ts = raw === undefined ? Date.now() : typeof raw === "number" ? raw : Date.parse(raw);
    const recorded = recordTap(db, ts, body.data?.id);
    reply.code(recorded ? 201 : 200);
    return { ts, recorded };
  });

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
