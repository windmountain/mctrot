import { z } from "zod";
import { latestAttempt } from "./attempts.ts";
import type { Db } from "./db.ts";
import type { RoutePlan } from "./plan.ts";
import { recentPosts } from "./posts.ts";
import { skyNow } from "./sky.ts";
import { newYorkDate, sunTimes } from "./sun.ts";
import { NO_ATTEMPT_WINDOW_MS, track } from "./track.ts";
import { latestSkyInputs, latestWeather, WEATHER_POINT } from "./weather.ts";
import { matchVisits, positionFromDb, tapsBetween } from "./visits.ts";

// The /live response: everything the public page needs, in one call. This
// zod schema is the contract. api/live.schema.json is generated from it
// (`npm run schema`; a test fails when it's stale), and website/src/Live.elm's
// decoder follows it.
const clip = z.object({ url: z.string().describe("The clip's .mp4"), posterUrl: z.string().nullable() });
const msOrNull = (what: string) =>
  z.number().int().nullable().describe(`${what}, ms since epoch; null if it doesn't happen that day`);
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
    track: z
      .array(z.array(z.tuple([z.number(), z.number()])))
      .describe(
        "The path walked as [lat, lon] lines, simplified, split where GPS was lost: this attempt's, or the last day's before any attempt",
      ),
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
          ts: ms("When I made it"),
          type: z.enum(["text", "photo", "video", "voice", "pair"]),
          text: z.string().nullable().describe("A text post's text"),
          media: z
            .object({
              url: z.string().describe("Photo: full size; video: .mp4; voice: .m4a; pair: the cut in its order"),
              thumbUrl: z.string().nullable().describe("Photo: about 400 px"),
              posterUrl: z.string().nullable().describe("Video: a frame"),
              width: z.number().int().nullable(),
              height: z.number().int().nullable(),
              durationMs: z.number().int().nullable(),
            })
            .nullable()
            .describe("Null for text posts"),
          pair: z
            .object({
              order: z.enum(["AB", "BA"]).describe("Which camera comes first"),
              a: clip,
              b: clip,
            })
            .nullable()
            .describe("A DoubleTake pair's two clips (A and B cameras), for a side-by-side player; null otherwise"),
          at: z
            .object({ lat: z.number(), lon: z.number() })
            .nullable()
            .describe("Where I was, from the GPS track; null when unknown"),
        }),
      )
      .describe("The newest posts first; photos, video, voice and DoubleTake pairs once processed"),
  })
  .extend({
    weather: z
      .object({
        place: z.object({ name: z.string(), lat: z.number(), lon: z.number() }).describe("Where all weather and sun times are for"),
        observedAt: ms("The reading's own time (Open-Meteo updates every 15 minutes)"),
        fetchedAt: ms("When the recorder fetched it"),
        temperatureF: z.number().nullable(),
        feelsLikeF: z.number().nullable(),
        humidityPct: z.number().nullable(),
        precipitationIn: z.number().nullable().describe("In the reading's 15 minutes"),
        summary: z.string().nullable().describe('From the WMO weather code: "Light rain"'),
        cloudCoverPct: z.number().nullable(),
        windMph: z.number().nullable(),
        gustMph: z.number().nullable(),
        windFrom: z.string().nullable().describe('Compass point the wind blows from: "NW"'),
        isDay: z.boolean().nullable(),
      })
      .nullable()
      .describe("The latest weather reading in central Manhattan; null before the first"),
    sun: z
      .object({
        date: z.string().describe("Today in New York, YYYY-MM-DD"),
        astronomicalDawn: msOrNull("Sun 18° below the horizon, rising"),
        nauticalDawn: msOrNull("12° below, rising"),
        civilDawn: msOrNull("6° below, rising"),
        sunrise: msOrNull("Sunrise"),
        solarNoon: ms("The sun at its highest"),
        sunset: msOrNull("Sunset"),
        civilDusk: msOrNull("6° below, setting"),
        nauticalDusk: msOrNull("12° below, setting"),
        astronomicalDusk: msOrNull("18° below, setting"),
      })
      .describe("Sun times for today in New York, at the weather's place"),
    sky: z
      .object({
        at: ms("The minute it's for"),
        sun: z.object({
          elevation: z.number().describe("Degrees above the horizon; negative below"),
          azimuth: z.number().describe("Compass bearing, 0 north, 90 east"),
        }),
        squares: z.array(
          z.object({
            label: z.string().describe('Where to look: "Low in the SW, toward the sun"'),
            elevation: z.number(),
            azimuth: z.number(),
            color: z.string().describe("CSS hex colour"),
          }),
        ),
      })
      .describe("The sky's colour in a few directions, simulated from the sun and the latest weather (src/sky.ts)"),
  })
  .meta({ title: "McTrot /live response" });

export type Live = z.infer<typeof LiveResponse>;

export function live(db: Db, plan: RoutePlan, mediaUrl: string, now = Date.now()): Live {
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
  const path = attempt
    ? track(db, attempt.startedAt, attempt.endedAt ?? Number.MAX_SAFE_INTEGER)
    : track(db, now - NO_ATTEMPT_WINDOW_MS, Number.MAX_SAFE_INTEGER);
  return {
    serverTs: now,
    position: position ?? null,
    attempt,
    stores,
    track: path,
    visits,
    posts: recentPosts(db, mediaUrl, 50, now),
    weather: (() => {
      const w = latestWeather(db);
      return w ? { place: WEATHER_POINT, ...w } : null;
    })(),
    sun: sunTimes(newYorkDate(now), WEATHER_POINT.lat, WEATHER_POINT.lon),
    sky: skyNow(now, WEATHER_POINT.lat, WEATHER_POINT.lon, latestSkyInputs(db)),
  };
}

export function liveJsonSchema() {
  return z.toJSONSchema(LiveResponse);
}
