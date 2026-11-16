import { createHash, timingSafeEqual } from "node:crypto";
import type { FastifyReply, FastifyRequest } from "fastify";

// Overland sends its access token as "Authorization: Bearer <token>".
// Tokens are never accepted in the URL, which would land in logs.
function bearer(req: FastifyRequest): string | undefined {
  const header = req.headers.authorization;
  const match = header?.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim();
}

// Compare digests so the comparison takes the same time for any input.
function same(a: string, b: string): boolean {
  const digest = (s: string) => createHash("sha256").update(s).digest();
  return timingSafeEqual(digest(a), digest(b));
}

// Returns true if the request may continue; otherwise it has replied.
export function requireToken(
  expected: string | undefined,
  req: FastifyRequest,
  reply: FastifyReply,
): boolean {
  if (expected === undefined) {
    // Misconfigured server. 503 makes Overland keep the batch and retry.
    reply.code(503).send({ error: "ingest token not configured" });
    return false;
  }
  const given = bearer(req);
  if (given === undefined || !same(given, expected)) {
    reply.code(401).send({ error: "bad or missing token" });
    return false;
  }
  return true;
}
