import { z } from "zod";
import { latestAttempt } from "./attempts.ts";
import type { Db } from "./db.ts";
import type { RoutePlan } from "./plan.ts";
import { recentPosts } from "./posts.ts";
import { matchVisits, positionFromDb, tapsBetween } from "./visits.ts";

// The /live response: everything the public page needs, in one call. This
// zod schema is the contract. api/live.schema.json is generated from it
// (`npm run schema`; a test fails when it's stale), and website/src/Live.elm's
// decoder follows it.
const ms = (what: string) => z.number().int().describe(`${what}, ms since epoch`);

export const LiveResponse = z
  .object({
    serverTs: ms("Server clock"),
    position: z
      .object({
        ts: ms("When the phone recorded it"),
        lat: z.number(),
        lon: z.number(),
        accuracy: z.number().nullable().describe("Horizontal accuracy in metres"),
      })
      .nullable()
      .describe("The latest recorded point; null before any"),
    attempt: z
      .object({
        id: z.number().int(),
        startedAt: ms("Started"),
        endedAt: ms("Stopped").nullable().describe("Null while the attempt is running"),
      })
      .nullable()
      .describe("The running attempt, or else the most recent; null before any"),
    stores: z
      .array(
        z.object({
          id: z.string(),
          name: z.string(),
          address: z.string(),
          lat: z.number(),
          lon: z.number(),
        }),
      )
      .describe("The route plan's stores"),
    visits: z
      .array(
        z.discriminatedUnion("status", [
          z.object({
            tapTs: ms("When I tapped Visit"),
            status: z.literal("matched"),
            storeId: z.string(),
            distanceM: z.number().describe("From my position at the tap to the store"),
          }),
          z.object({
            tapTs: ms("When I tapped Visit"),
            status: z.literal("pending").describe("Waiting for GPS from after the tap"),
          }),
          z.object({
            tapTs: ms("When I tapped Visit"),
            status: z.literal("unmatched").describe("No store near, or no GPS near the tap"),
          }),
        ]),
      )
      .describe("This attempt's Visit taps in time order, each matched to a store by GPS"),
    posts: z
      .array(
        z.object({
          id: z.string(),
          ts: ms("When I wrote it"),
          type: z.literal("text"),
          text: z.string(),
          at: z
            .object({ lat: z.number(), lon: z.number() })
            .nullable()
            .describe("Where I was, from the GPS track; null when unknown"),
        }),
      )
      .describe("The newest posts first"),
  })
  .meta({ title: "McTrot /live response" });

export type Live = z.infer<typeof LiveResponse>;

export function live(db: Db, plan: RoutePlan, now = Date.now()): Live {
  const position = db
    .prepare("select ts, lat, lon, accuracy from points order by ts desc limit 1")
    .get() as Live["position"] | undefined;
  const attempt = latestAttempt(db);
  const visits = attempt
    ? matchVisits(
        tapsBetween(db, attempt.startedAt, attempt.endedAt ?? Number.MAX_SAFE_INTEGER),
        plan.stores,
        (ts) => positionFromDb(db, ts),
      )
    : [];
  const stores = plan.stores.map(({ id, name, address, lat, lon }) => ({ id, name, address, lat, lon }));
  return { serverTs: now, position: position ?? null, attempt, stores, visits, posts: recentPosts(db) };
}

export function liveJsonSchema() {
  return z.toJSONSchema(LiveResponse);
}
