import { z } from "zod";
import type { Db } from "./db.ts";

// The /live response: everything the public page needs, in one call. This
// zod schema is the contract. api/live.schema.json is generated from it
// (`npm run schema`; a test fails when it's stale), and website/src/Live.elm's
// decoder follows it.
export const LiveResponse = z
  .object({
    serverTs: z.number().int().describe("Server clock, ms since epoch"),
    position: z
      .object({
        ts: z.number().int().describe("When the phone recorded it, ms since epoch"),
        lat: z.number(),
        lon: z.number(),
        accuracy: z.number().nullable().describe("Horizontal accuracy in metres"),
      })
      .nullable()
      .describe("The latest recorded point; null before any"),
  })
  .meta({ title: "McTrot /live response" });

export type Live = z.infer<typeof LiveResponse>;

export function live(db: Db, now = Date.now()): Live {
  const row = db
    .prepare("select ts, lat, lon, accuracy from points order by ts desc limit 1")
    .get() as Live["position"] | undefined;
  return { serverTs: now, position: row ?? null };
}

export function liveJsonSchema() {
  return z.toJSONSchema(LiveResponse);
}
