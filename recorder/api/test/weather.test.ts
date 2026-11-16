import assert from "node:assert/strict";
import { test } from "node:test";
import { newYorkDate, sunTimes } from "../src/sun.ts";
import { compass, latestWeather, saveWeather, WEATHER_POINT } from "../src/weather.ts";
import { setup } from "./helpers.ts";

// Open-Meteo's answer, as fetched from it on 2026-11-16.
const SAMPLE = {
  latitude: 40.78858,
  longitude: -73.9661,
  current: {
    time: 1794852000,
    interval: 900,
    temperature_2m: 53.9,
    relative_humidity_2m: 49,
    apparent_temperature: 46.9,
    is_day: 1,
    precipitation: 0,
    weather_code: 61,
    cloud_cover: 2,
    wind_speed_10m: 8.7,
    wind_direction_10m: 324,
    wind_gusts_10m: 12.1,
  },
};

test("a reading is saved and /live shows the latest", async () => {
  const { app, db } = await setup();
  assert.equal((await app.inject({ url: "/live" })).json().weather, null, "none before the first fetch");
  saveWeather(db, { current: { ...SAMPLE.current, time: 1794851100, temperature_2m: 50 } }, 1000);
  saveWeather(db, SAMPLE, 2000);
  const w = (await app.inject({ url: "/live" })).json().weather;
  assert.deepEqual(w, {
    place: WEATHER_POINT,
    observedAt: 1794852000000,
    fetchedAt: 2000,
    temperatureF: 53.9,
    feelsLikeF: 46.9,
    humidityPct: 49,
    precipitationIn: 0,
    summary: "Light rain",
    cloudCoverPct: 2,
    windMph: 8.7,
    gustMph: 12.1,
    windFrom: "NW",
    isDay: true,
  });
  assert.equal(db.prepare("select count(*) from weather").pluck().get(), 2, "every fetch is kept");
});

test("missing fields are kept as unknown, and a broken answer is refused", async () => {
  const { db } = await setup();
  saveWeather(db, { current: { time: 1794852000, temperature_2m: null } }, 1);
  const w = latestWeather(db)!;
  assert.equal(w.temperatureF, null);
  assert.equal(w.summary, null);
  assert.throws(() => saveWeather(db, { error: true, reason: "nope" }, 2));
});

test("compass points", () => {
  assert.deepEqual([0, 22, 23, 90, 180, 324, 359].map(compass), ["N", "NNE", "NNE", "E", "S", "NW", "N"]);
});

// Published times for Central Park (NOAA's solar calculator) agree to within a minute.
const at = (iso: string) => Date.parse(iso);
const near = (actual: number | null, expected: number, label: string) =>
  assert.ok(actual !== null && Math.abs(actual - expected) <= 60_000, `${label}: ${actual && new Date(actual).toISOString()}`);

test("sun times on the day of the walk, November 21, 2026 (EST)", () => {
  const t = sunTimes("2026-11-21", WEATHER_POINT.lat, WEATHER_POINT.lon);
  near(t.astronomicalDawn, at("2026-11-21T10:14:00Z"), "astronomical dawn 5:14 AM");
  near(t.civilDawn, at("2026-11-21T11:20:00Z"), "civil dawn 6:20 AM");
  near(t.sunrise, at("2026-11-21T11:50:00Z"), "sunrise 6:50 AM");
  near(t.sunset, at("2026-11-21T21:33:00Z"), "sunset 4:33 PM");
  near(t.civilDusk, at("2026-11-21T22:03:00Z"), "civil dusk 5:03 PM");
  near(t.astronomicalDusk, at("2026-11-21T23:09:00Z"), "astronomical dusk 6:09 PM");
  assert.ok(t.nauticalDawn! > t.astronomicalDawn! && t.nauticalDawn! < t.civilDawn!);
  assert.ok(t.solarNoon > t.sunrise! && t.solarNoon < t.sunset!);
});

test("sun times in June (EDT): astronomical dusk runs past midnight UTC", () => {
  const t = sunTimes("2026-06-21", WEATHER_POINT.lat, WEATHER_POINT.lon);
  near(t.sunrise, at("2026-06-21T09:25:00Z"), "sunrise 5:25 AM");
  near(t.sunset, at("2026-06-21T00:31:00Z") + 86_400_000, "sunset 8:31 PM");
  assert.equal(newYorkDate(t.astronomicalDusk!), "2026-06-21", "still the same day in New York");
});

test("/live's sun times are for today in New York, not UTC", async () => {
  const { app } = await setup();
  const sun = (await app.inject({ url: "/live" })).json().sun;
  assert.equal(sun.date, newYorkDate(Date.now()));
  assert.equal(newYorkDate(at("2026-11-22T03:00:00Z")), "2026-11-21", "10 PM EST is still the 21st");
});
