import Fastify, { type FastifyInstance } from "fastify";
import { type Db, dbStatus } from "./db.ts";

export type AppDeps = {
  db: Db;
  // Git revision of the deployed flake; changes with every deploy.
  version: string;
  startedAt: Date;
  // Names of secrets that loaded, never their values.
  secrets: Record<string, boolean>;
  logger?: boolean;
};

export function buildApp(deps: AppDeps): FastifyInstance {
  const app = Fastify({ logger: deps.logger ?? false });

  app.get("/", async () => "hello from mctrot\n");

  app.get("/health", async (_req, reply) => {
    const database = dbStatus(deps.db);
    reply.code(database.ok ? 200 : 503);
    return {
      version: deps.version,
      startedAt: deps.startedAt.toISOString(),
      uptimeSeconds: Math.round((Date.now() - deps.startedAt.getTime()) / 1000),
      database,
      secrets: deps.secrets,
    };
  });

  return app;
}
