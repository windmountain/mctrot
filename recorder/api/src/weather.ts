// The weather in central Manhattan, from Open-Meteo (https://open-meteo.com:
// free, no account or key). mctrot-weather (host/api.nix) runs this file
// every 10 minutes to save one reading; /live shows the latest.
//
//   MCTROT_DB=... node src/weather.ts     fetch and save one reading
import { pathToFileURL } from "node:url";
import { z } from "zod";
import { type Db, openDb } from "./db.ts";

// One point for all of the walk's weather and sun times: the usual centre
// of Manhattan, in Central Park near 81st Street.
export const WEATHER_POINT = { name: "Central Manhattan", lat: 40.7831, lon: -73.9712 };

const FIELDS = [
  "temperature_2m", "apparent_temperature", "relative_humidity_2m", "precipitation", "weather_code",
  "cloud_cover", "wind_speed_10m", "wind_gusts_10m", "wind_direction_10m", "is_day",
] as const;

export const WEATHER_URL =
  "https://api.open-meteo.com/v1/forecast" +
  `?latitude=${WEATHER_POINT.lat}&longitude=${WEATHER_POINT.lon}` +
  `&current=${FIELDS.join(",")}` +
  "&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch&timeformat=unixtime";

const num = z.number().nullable().optional();
const OpenMeteo = z.object({
  current: z.object({
    time: z.number().int(),
    temperature_2m: num,
    apparent_temperature: num,
    relative_humidity_2m: num,
    precipitation: num,
    weather_code: num,
    cloud_cover: num,
    wind_speed_10m: num,
    wind_gusts_10m: num,
    wind_direction_10m: num,
    is_day: num,
  }),
});

export function saveWeather(db: Db, body: unknown, now = Date.now()) {
  const c = OpenMeteo.parse(body).current;
  const v = (x: number | null | undefined) => x ?? null;
  db.prepare(
    `insert or replace into weather (fetched_at, observed_at, temperature_f, feels_like_f, humidity_pct,
       precipitation_in, weather_code, cloud_cover_pct, wind_mph, gust_mph, wind_from_deg, is_day, raw)
     values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    now, c.time * 1000, v(c.temperature_2m), v(c.apparent_temperature), v(c.relative_humidity_2m),
    v(c.precipitation), v(c.weather_code), v(c.cloud_cover), v(c.wind_speed_10m), v(c.wind_gusts_10m),
    v(c.wind_direction_10m), c.is_day === null || c.is_day === undefined ? null : c.is_day ? 1 : 0,
    JSON.stringify(body),
  );
}

export type Weather = {
  observedAt: number;
  fetchedAt: number;
  temperatureF: number | null;
  feelsLikeF: number | null;
  humidityPct: number | null;
  precipitationIn: number | null;
  summary: string | null;
  cloudCoverPct: number | null;
  windMph: number | null;
  gustMph: number | null;
  windFrom: string | null; // compass point, "NW"
  isDay: boolean | null;
};

export function latestWeather(db: Db): Weather | null {
  const r = db.prepare("select * from weather order by fetched_at desc limit 1").get() as
    | {
        fetched_at: number; observed_at: number; temperature_f: number | null; feels_like_f: number | null;
        humidity_pct: number | null; precipitation_in: number | null; weather_code: number | null;
        cloud_cover_pct: number | null; wind_mph: number | null; gust_mph: number | null;
        wind_from_deg: number | null; is_day: number | null;
      }
    | undefined;
  if (!r) return null;
  return {
    observedAt: r.observed_at,
    fetchedAt: r.fetched_at,
    temperatureF: r.temperature_f,
    feelsLikeF: r.feels_like_f,
    humidityPct: r.humidity_pct,
    precipitationIn: r.precipitation_in,
    summary: r.weather_code === null ? null : (WMO[r.weather_code] ?? null),
    cloudCoverPct: r.cloud_cover_pct,
    windMph: r.wind_mph,
    gustMph: r.gust_mph,
    windFrom: r.wind_from_deg === null ? null : compass(r.wind_from_deg),
    isDay: r.is_day === null ? null : r.is_day === 1,
  };
}

const POINTS = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"];
export const compass = (deg: number) => POINTS[Math.round((((deg % 360) + 360) % 360) / 22.5) % 16]!;

// WMO weather interpretation codes, as Open-Meteo documents them.
export const WMO: Record<number, string> = {
  0: "Clear", 1: "Mostly clear", 2: "Partly cloudy", 3: "Overcast",
  45: "Fog", 48: "Freezing fog",
  51: "Light drizzle", 53: "Drizzle", 55: "Heavy drizzle", 56: "Light freezing drizzle", 57: "Freezing drizzle",
  61: "Light rain", 63: "Rain", 65: "Heavy rain", 66: "Light freezing rain", 67: "Freezing rain",
  71: "Light snow", 73: "Snow", 75: "Heavy snow", 77: "Snow grains",
  80: "Light showers", 81: "Showers", 82: "Heavy showers", 85: "Light snow showers", 86: "Snow showers",
  95: "Thunderstorm", 96: "Thunderstorm with hail", 99: "Thunderstorm with heavy hail",
};

// Run by mctrot-weather: one fetch, one row. A failure exits non-zero so
// systemd logs it; the next run in 10 minutes tries again.
async function main() {
  const { db } = openDb(process.env.MCTROT_DB ?? "dev.sqlite", "never");
  try {
    const res = await fetch(WEATHER_URL, {
      headers: { "user-agent": "mctrot-recorder (https://mctrot.nyc)" },
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) throw new Error(`Open-Meteo answered ${res.status}: ${(await res.text()).slice(0, 200)}`);
    saveWeather(db, await res.json());
    const w = latestWeather(db)!;
    console.log(`weather: ${w.temperatureF}°F, ${w.summary}, observed ${new Date(w.observedAt).toISOString()}`);
  } finally {
    db.close();
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) await main();
