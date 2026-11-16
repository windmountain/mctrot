import type { FastifyReply, FastifyRequest } from "fastify";
import { tokenMatches } from "./auth.ts";

// The upload page's sign-in: a signed cookie holding its expiry time.
// Signed with the session secret (@fastify/cookie, registered in app.ts);
// HttpOnly, and SameSite=Strict so other sites can't send it along.
export const SESSION_COOKIE = "mctrot_session";
export const SESSION_DAYS = 180;

export type SessionConfig = {
  // Where the upload page is served from, e.g. "https://api.mctrot.nyc".
  origin: string;
};

export function startSession(reply: FastifyReply, config: SessionConfig, now = Date.now()) {
  const maxAge = SESSION_DAYS * 86_400;
  reply.setCookie(SESSION_COOKIE, String(now + maxAge * 1000), {
    signed: true,
    httpOnly: true,
    secure: config.origin.startsWith("https://"),
    sameSite: "strict",
    path: "/",
    maxAge,
  });
}

export function endSession(reply: FastifyReply) {
  reply.clearCookie(SESSION_COOKIE, { path: "/" });
}

export function hasSession(req: FastifyRequest, now = Date.now()): boolean {
  const raw = req.cookies[SESSION_COOKIE];
  if (!raw) return false;
  const { valid, value } = req.unsignCookie(raw);
  return valid && value !== null && Number(value) > now;
}

// Writes (posts, visits, attempts) come from the upload page, with its
// session cookie, or from curl, with the ingest token. A cookie only
// counts on a request from the page's own origin; browsers always send
// Origin on POSTs, so a request from anywhere else is turned away.
export function requireWriter(
  ingestToken: string | undefined,
  config: SessionConfig,
  req: FastifyRequest,
  reply: FastifyReply,
): boolean {
  if (tokenMatches(ingestToken, req)) return true;
  const origin = req.headers.origin;
  if (hasSession(req) && (origin === undefined || origin === config.origin)) return true;
  reply.code(401).send({ error: "sign in, or send the ingest token" });
  return false;
}
