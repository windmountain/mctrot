import { readFileSync } from "node:fs";
import { join } from "node:path";
import { buildApp } from "./app.ts";
import { openDb } from "./db.ts";

// Configuration comes from the environment, set by the systemd unit in
// host/api.nix. The defaults are for running on a laptop.
const env = process.env;
const port = Number(env.PORT ?? 3000);
const host = env.HOST ?? "127.0.0.1";
const dbPath = env.MCTROT_DB ?? "dev.sqlite";
const version = env.MCTROT_VERSION ?? "dev";
const resetPolicy = env.MCTROT_DB_RESET === "never" ? "never" : "reset";

// Secrets arrive as files via systemd's LoadCredential, so they never sit
// in the environment or the Nix store. Locally, MCTROT_INGEST_TOKEN works.
function readSecret(name: string): string | undefined {
  const dir = env.CREDENTIALS_DIRECTORY;
  if (!dir) return undefined;
  try {
    return readFileSync(join(dir, name), "utf8").trim() || undefined;
  } catch {
    return undefined;
  }
}

const ingestToken = readSecret("ingest-token") ?? (env.MCTROT_INGEST_TOKEN || undefined);

const { db, archived } = openDb(dbPath, resetPolicy);
const app = buildApp({
  db,
  version,
  startedAt: new Date(),
  ingestToken,
  logger: true,
});
if (archived) {
  app.log.warn({ archived }, "schema changed: old database moved aside, starting empty");
}

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, async () => {
    await app.close();
    db.close();
    process.exit(0);
  });
}

await app.listen({ port, host });
