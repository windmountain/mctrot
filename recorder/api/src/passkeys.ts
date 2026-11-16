// Passkeys (Face ID) for the upload page, with @simplewebauthn/server.
// One person, so no user accounts: any registered passkey signs in.
// Registering one needs an existing session (from the ingest token, the
// first time; see app.ts's /auth/token).
import { randomUUID } from "node:crypto";
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from "@simplewebauthn/server";
import type {
  AuthenticationResponseJSON,
  RegistrationResponseJSON,
  WebAuthnCredential,
} from "@simplewebauthn/server";
import type { Db } from "./db.ts";

export type PasskeyConfig = {
  // The page's origin, e.g. "https://api.mctrot.nyc".
  origin: string;
  // The passkey's domain: "mctrot.nyc", so it works on any subdomain.
  rpID: string;
};

// Each ceremony's challenge, kept in memory for a few minutes under a flow
// id the page sends back. One process, one person: no need for more.
const CHALLENGE_MS = 5 * 60_000;
const challenges = new Map<string, { challenge: string; expires: number }>();

function remember(challenge: string): string {
  const now = Date.now();
  for (const [id, c] of challenges) if (c.expires < now) challenges.delete(id);
  const flowId = randomUUID();
  challenges.set(flowId, { challenge, expires: now + CHALLENGE_MS });
  return flowId;
}

function takeChallenge(flowId: unknown): string | undefined {
  if (typeof flowId !== "string") return undefined;
  const c = challenges.get(flowId);
  challenges.delete(flowId);
  return c && c.expires >= Date.now() ? c.challenge : undefined;
}

type Row = { id: string; public_key: Buffer; counter: number; transports: string };

function credentials(db: Db): WebAuthnCredential[] {
  return (db.prepare("select * from passkeys").all() as Row[]).map((r) => ({
    id: r.id,
    publicKey: new Uint8Array(r.public_key),
    counter: r.counter,
    transports: JSON.parse(r.transports) as WebAuthnCredential["transports"],
  }));
}

export function passkeyCount(db: Db): number {
  return db.prepare("select count(*) from passkeys").pluck().get() as number;
}

export async function registrationOptions(db: Db, config: PasskeyConfig) {
  const options = await generateRegistrationOptions({
    rpName: "McTrot",
    rpID: config.rpID,
    userName: "mctrotter",
    userDisplayName: "McTrot",
    attestationType: "none",
    excludeCredentials: credentials(db).map((c) => ({ id: c.id, transports: c.transports })),
    authenticatorSelection: { residentKey: "preferred", userVerification: "required" },
  });
  return { flowId: remember(options.challenge), options };
}

export async function registerPasskey(
  db: Db,
  config: PasskeyConfig,
  flowId: unknown,
  response: RegistrationResponseJSON,
): Promise<boolean> {
  const expectedChallenge = takeChallenge(flowId);
  if (!expectedChallenge) return false;
  const result = await verifyRegistrationResponse({
    response,
    expectedChallenge,
    expectedOrigin: config.origin,
    expectedRPID: config.rpID,
    requireUserVerification: true,
  }).catch(() => ({ verified: false as const }));
  if (!result.verified) return false;
  const { credential } = result.registrationInfo;
  db.prepare(
    `insert or replace into passkeys (id, public_key, counter, transports, created_at)
     values (?, ?, ?, ?, ?)`,
  ).run(
    credential.id,
    Buffer.from(credential.publicKey),
    credential.counter,
    JSON.stringify(credential.transports ?? []),
    Date.now(),
  );
  return true;
}

export async function authenticationOptions(db: Db, config: PasskeyConfig) {
  const options = await generateAuthenticationOptions({
    rpID: config.rpID,
    allowCredentials: credentials(db).map((c) => ({ id: c.id, transports: c.transports })),
    userVerification: "required",
  });
  return { flowId: remember(options.challenge), options };
}

export async function authenticate(
  db: Db,
  config: PasskeyConfig,
  flowId: unknown,
  response: AuthenticationResponseJSON,
): Promise<boolean> {
  const expectedChallenge = takeChallenge(flowId);
  if (!expectedChallenge) return false;
  const credential = credentials(db).find((c) => c.id === response?.id);
  if (!credential) return false;
  const result = await verifyAuthenticationResponse({
    response,
    expectedChallenge,
    expectedOrigin: config.origin,
    expectedRPID: config.rpID,
    credential,
    requireUserVerification: true,
  }).catch(() => ({ verified: false, authenticationInfo: undefined }));
  if (!result.verified || !result.authenticationInfo) return false;
  db.prepare("update passkeys set counter = ? where id = ?").run(
    result.authenticationInfo.newCounter,
    credential.id,
  );
  return true;
}
