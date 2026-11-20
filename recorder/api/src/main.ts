import { readFileSync } from "node:fs";
import { join } from "node:path";
import { buildApp } from "./app.ts";
import { openDb } from "./db.ts";
import { logMailer, mailgun, type Mailer } from "./guests/mail.ts";
import { loadPlan } from "./plan.ts";
import { programReader } from "./radio.ts";

// Configuration comes from the environment, set by the systemd unit in
// host/api.nix. The defaults are for running on a laptop.
const env = process.env;
const port = Number(env.PORT ?? 3000);
const host = env.HOST ?? "127.0.0.1";
const dbPath = env.MCTROT_DB ?? "dev.sqlite";
const version = env.MCTROT_VERSION ?? "dev";
// JSON made from the route GPX (tools/route_plan.py); unset means no stores.
const planPath = env.MCTROT_ROUTE_PLAN || undefined;
// Where the upload page is served from, and its passkeys' domain. On the box:
// https://api.mctrot.nyc and mctrot.nyc (host/api.nix).
const origin = env.MCTROT_ORIGIN ?? `http://localhost:${port}`;
const rpID = env.MCTROT_RP_ID ?? "localhost";
// The upload page's files: recorder/post/, next to this package.
const postDir = env.MCTROT_POST_DIR ?? new URL("../../post/", import.meta.url).pathname;
// Finished uploads wait here for the worker; the worker writes the media
// folder, which is served at MCTROT_MEDIA_URL (media.mctrot.nyc on the box).
const uploadDir = env.MCTROT_UPLOAD_DIR ?? "uploads";
const mediaUrl = env.MCTROT_MEDIA_URL ?? `http://localhost:${port}/media`;
const mediaDir = env.MCTROT_MEDIA_DIR ?? "media";
// McTrot radio's program.json, uploaded by hand next to its show file
// (host/radio.nix); unset or missing means off air.
const radioPath = env.MCTROT_RADIO_PROGRAM || undefined;
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
const sessionSecret = readSecret("session-secret") ?? (env.MCTROT_SESSION_SECRET || undefined);

// Guest accounts (src/guests/), always on. Codes go out through Mailgun
// when its API key is a credential; without one (locally), they're printed
// to the log instead.
const siteOrigin = env.MCTROT_SITE_ORIGIN ?? "http://localhost:8000";
const mailgunKey = readSecret("mailgun-api-key") ?? (env.MCTROT_MAILGUN_API_KEY || undefined);
const mailer: Mailer = mailgunKey
  ? mailgun({
      baseUrl: env.MCTROT_MAILGUN_URL ?? "https://api.eu.mailgun.net",
      domain: env.MCTROT_MAILGUN_DOMAIN ?? "mg.mctrot.nyc",
      apiKey: mailgunKey,
      from: env.MCTROT_MAIL_FROM ?? "McTrot <noreply@mg.mctrot.nyc>",
    })
  : logMailer((message) => console.log(message));
if (!mailgunKey && env.NODE_ENV === "production") {
  console.warn("no mailgun-api-key: guests' sign-in codes are only printed to this log, not emailed");
}

const plan = loadPlan(planPath);
const { db, archived } = openDb(dbPath, resetPolicy);
const app = await buildApp({
  db,
  plan,
  version,
  startedAt: new Date(),
  ingestToken,
  sessionSecret,
  origin,
  rpID,
  postDir,
  uploadDir,
  mediaUrl,
  mediaDir,
  radioProgram: programReader(radioPath, (message) => console.warn(message)),
  guests: { siteOrigin, mailer },
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
