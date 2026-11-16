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

// Secrets arrive as files via systemd's LoadCredential, so they never sit
// in the environment or the Nix store.
function readSecret(name: string): string | undefined {
  const dir = env.CREDENTIALS_DIRECTORY;
  if (!dir) return undefined;
  try {
    return readFileSync(join(dir, name), "utf8").trim() || undefined;
  } catch {
    return undefined;
  }
}

const ingestToken = readSecret("ingest-token");

const db = openDb(dbPath);
const app = buildApp({
  db,
  version,
  startedAt: new Date(),
  secrets: { ingestToken: ingestToken !== undefined },
  logger: true,
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, async () => {
    await app.close();
    db.close();
    process.exit(0);
  });
}

await app.listen({ port, host });
