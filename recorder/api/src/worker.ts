// The media worker: its own service (mctrot-worker, host/api.nix), run at
// low priority so processing video can never starve the radio of CPU.
// Takes one job at a time from the database the API writes.
import { openDb } from "./db.ts";
import { processNext, requeueAbandoned } from "./jobs.ts";

const env = process.env;
const dbPath = env.MCTROT_DB ?? "dev.sqlite";
const mediaDir = env.MCTROT_MEDIA_DIR ?? "media";
const IDLE_MS = 2000;

// "never": the API owns the schema; the worker never resets a database.
const { db } = openDb(dbPath, "never");
const requeued = requeueAbandoned(db);
if (requeued) console.log(`requeued ${requeued} job(s) left running`);

let stopping = false;
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => {
    stopping = true;
  });
}

console.log(`worker: ${dbPath} -> ${mediaDir}`);
while (!stopping) {
  const started = Date.now();
  const worked = await processNext(db, mediaDir).catch((err) => {
    console.error("worker error", err);
    return false;
  });
  if (worked) console.log(`job done in ${Date.now() - started} ms`);
  else await new Promise((r) => setTimeout(r, IDLE_MS));
}
db.close();
