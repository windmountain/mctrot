import Fastify, { type FastifyInstance } from "fastify";
import { requireToken } from "./auth.ts";
import { type Db, dbStatus } from "./db.ts";
import { live } from "./live.ts";
import { lastPoints, OverlandBatch, storePoints } from "./points.ts";

export type AppDeps = {
  db: Db;
  // Git revision of the deployed flake; changes with every deploy.
  version: string;
  startedAt: Date;
  // Overland's access token; also guards the debug routes.
  ingestToken: string | undefined;
  logger?: boolean;
};

export function buildApp(deps: AppDeps): FastifyInstance {
  const { db, ingestToken } = deps;
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

  // The public page's one call (website/live.html, on another origin).
  // Public data, so any origin may read it; never cached, it's live.
  app.get("/live", async (_req, reply) => {
    reply.header("access-control-allow-origin", "*");
    reply.header("cache-control", "no-store");
    return live(db);
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
