// The simulated sky: not exact colours (it's a model), but the things any
// sky does.
import assert from "node:assert/strict";
import { test } from "node:test";
import { sky } from "../src/sky.ts";
import { sunPosition } from "../src/sun.ts";
import type { SkyInputs } from "../src/weather.ts";
import { setup } from "./helpers.ts";

const LAT = 40.7831;
const LON = -73.9712;
const rgb = (hex: string) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16)) as [number, number, number];
const bright = (hex: string) => rgb(hex).reduce((a, b) => a + b, 0) / 3;
const spread = (hex: string) => Math.max(...rgb(hex)) - Math.min(...rgb(hex));
const at = (iso: string) => Date.parse(iso);
const weather = (over: Partial<SkyInputs> = {}): SkyInputs => ({
  observedAt: 0, cloudCoverPct: 0, lowPct: 0, midPct: 0, highPct: 0, visibilityFt: 100_000, ...over,
});
const colours = (iso: string, w: SkyInputs | null = weather()) => sky(at(iso), LAT, LON, w).squares.map((q) => q.color);
// The tile with this label.
const tile = (iso: string, label: string, w: SkyInputs | null = weather()) =>
  sky(at(iso), LAT, LON, w).squares.find((q) => q.label === label)!.color;

test("the sun's position: high in the south at noon, rising in the ESE on the walk's morning", () => {
  const noon = sunPosition(at("2026-11-21T16:42:00Z"), LAT, LON);
  assert.ok(Math.abs(noon.azimuth - 180) < 2 && Math.abs(noon.elevation - 29.3) < 0.5, JSON.stringify(noon));
  const rise = sunPosition(at("2026-11-21T11:50:00Z"), LAT, LON);
  assert.ok(Math.abs(rise.elevation) < 1 && rise.azimuth > 110 && rise.azimuth < 125, JSON.stringify(rise));
});

test("clear midday: blue overhead, and the south (toward the sun) brighter than the north", () => {
  const noon = "2026-11-21T17:00:00Z";
  const overhead = tile(noon, "Overhead");
  const [r, , b] = rgb(overhead);
  assert.ok(b > r + 40, `overhead is blue: ${overhead}`);
  assert.ok(bright(tile(noon, "SE")) > bright(tile(noon, "NE")), "SE brighter than NE");
  assert.ok(bright(tile(noon, "SW")) > bright(tile(noon, "NW")), "SW brighter than NW");
});

// The sun rises in the ESE on the walk's morning: just before, the sun
// 2.5° down, the SE glows; the west is still dark.
test("dawn: the SE glows orange, the NW doesn't", () => {
  const dawn = "2026-11-21T11:40:00Z";
  const [r, , b] = rgb(tile(dawn, "SE"));
  assert.ok(r > b + 40, `SE is orange: ${tile(dawn, "SE")}`);
  assert.ok(bright(tile(dawn, "SE")) > bright(tile(dawn, "NW")) + 30, "SE brighter than NW");
});

test("night is dark; Manhattan's glow keeps it off black", () => {
  for (const c of colours("2026-11-22T03:00:00Z")) {
    assert.ok(bright(c) < 60 && bright(c) > 8, c);
  }
});

test("overcast at midday is grey, and lighter than night", () => {
  const grey = colours("2026-11-21T17:00:00Z", weather({ cloudCoverPct: 100, lowPct: 100 }));
  for (const c of grey) {
    assert.ok(spread(c) < 20, `grey: ${c}`);
    assert.ok(bright(c) > 100, `light: ${c}`);
  }
});

test("with no weather yet, the sky is still worked out (as clear)", () => {
  assert.equal(colours("2026-11-21T17:00:00Z", null).length, 5);
});

test("/live has the sky: overhead, then NE, NW, SE, SW", async () => {
  const { app } = await setup();
  const body = (await app.inject({ url: "/live" })).json();
  assert.deepEqual(
    body.sky.squares.map((q: { label: string }) => q.label),
    ["Overhead", "NE", "NW", "SE", "SW"],
  );
  for (const q of body.sky.squares) assert.match(q.color, /^#[0-9a-f]{6}$/);
});
