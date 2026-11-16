// The colour of the sky over central Manhattan, simulated: overhead and
// four compass points low in the sky, each a CSS colour, for /live's tiles.
//
// Clear sky: sunlight scattered once on its way through the air (as in
// Nishita et al. 1993 and Bruneton & Neyret 2008), at three wavelengths
// standing in for red, green and blue. Air molecules scatter blue most
// (Rayleigh); haze scatters all colours, mostly forward (Mie), and how much
// haze there is comes from the reported visibility; ozone absorbs orange,
// which keeps twilight blue. Single scattering is a known simplification:
// it makes deep twilight darker than it really is.
//
// Clouds: no model predicts their colour from a cloud-cover percentage, so
// the clear sky is blended toward a cloud colour (grey, lit by the sunlight
// that reaches cloud height, so it reddens at sunset) by the cloud cover;
// low cloud is darker. At night, Manhattan's own light glows orange, more
// so under cloud. Colours are shown as eyes adapted to the light would see
// them: dimmer skies get more exposure (up to a limit), so twilight reads
// as deep blue rather than black. A plausible sky, not a photograph.

import { sunPosition } from "./sun.ts";
import type { SkyInputs } from "./weather.ts";

type Vec = [number, number, number];
type RGB = [number, number, number];

const EARTH_R = 6_360_000; // m
const TOP_R = 6_420_000; // top of the atmosphere
const OBSERVER_H = 30; // m: street level, give or take

// Per metre at sea level, at about 680, 550 and 440 nm.
const RAYLEIGH: RGB = [5.802e-6, 13.558e-6, 33.1e-6];
const RAYLEIGH_H = 8000;
const MIE_H = 1200;
const MIE_ALBEDO = 0.9; // the rest of haze's extinction is absorption
const MIE_G = 0.76; // how strongly haze scatters forward
const OZONE: RGB = [0.65e-6, 1.881e-6, 0.085e-6];
const OZONE_PEAK = 25_000;
const OZONE_HALF_WIDTH = 15_000;
// Clean air if the visibility is unknown (about 60 km).
const DEFAULT_MIE = 30e-6;

const SUN = 20; // sunlight's strength; with EXPOSURE, sets the brightness
const EXPOSURE = 2;
// Eyes adapting: exposure rises as the square root of how much dimmer the
// overhead sky is than at midday, up to this many times.
const NOON_LUMINANCE = 0.13;
const MAX_ADAPTATION = 25;
const CITY_GLOW: RGB = [0.00028, 0.0002, 0.00017]; // Manhattan's light, at night
// Light scattered more than once, as a share of single scattering spread
// evenly in all directions: without it, thick haze would look dark rather
// than white. Mostly a haze effect; clear air keeps its blue.
const MULTIPLE_RAYLEIGH = 0.12 / (4 * Math.PI);
const MULTIPLE_MIE = 0.6 / (4 * Math.PI);

const VIEW_STEPS = 48;
const LIGHT_STEPS = 12;

const RAD = Math.PI / 180;
const luminance = (c: RGB) => 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
const dot = (a: Vec, b: Vec) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const add = (a: Vec, b: Vec, s = 1): Vec => [a[0] + b[0] * s, a[1] + b[1] * s, a[2] + b[2] * s];
const length = (a: Vec) => Math.sqrt(dot(a, a));

// x east, y up, z north.
function direction(elevation: number, azimuth: number): Vec {
  const e = elevation * RAD;
  const a = azimuth * RAD;
  return [Math.cos(e) * Math.sin(a), Math.sin(e), Math.cos(e) * Math.cos(a)];
}

// Distances along the ray to a sphere around the earth's centre; null if
// it misses.
function sphere(origin: Vec, dir: Vec, radius: number): [number, number] | null {
  const b = dot(origin, dir);
  const c = dot(origin, origin) - radius * radius;
  const d = b * b - c;
  if (d < 0) return null;
  const s = Math.sqrt(d);
  return [-b - s, -b + s];
}

type Air = { mie: number }; // haze's extinction per metre at sea level

function densities(p: Vec): [number, number, number] {
  const h = Math.max(0, length(p) - EARTH_R);
  return [
    Math.exp(-h / RAYLEIGH_H),
    Math.exp(-h / MIE_H),
    Math.max(0, 1 - Math.abs(h - OZONE_PEAK) / OZONE_HALF_WIDTH),
  ];
}

// How much light gets through, per colour, from optical depths.
function transmittance(air: Air, rayleigh: number, mie: number, ozone: number): RGB {
  return [0, 1, 2].map((i) => Math.exp(-(RAYLEIGH[i]! * rayleigh + air.mie * mie + OZONE[i]! * ozone))) as RGB;
}

// Optical depths from p to the top of the atmosphere toward the sun; null
// if the earth is in the way (p is in shadow).
function toSun(p: Vec, sun: Vec): [number, number, number] | null {
  const ground = sphere(p, sun, EARTH_R);
  if (ground && ground[0] > 0) return null;
  const top = sphere(p, sun, TOP_R)!;
  const ds = top[1] / LIGHT_STEPS;
  let r = 0;
  let m = 0;
  let o = 0;
  for (let i = 0; i < LIGHT_STEPS; i++) {
    const [dr, dm, dz] = densities(add(p, sun, (i + 0.5) * ds));
    r += dr * ds;
    m += dm * ds;
    o += dz * ds;
  }
  return [r, m, o];
}

// Light reaching the eye from one direction, linear, per colour.
function clearSky(view: Vec, sun: Vec, air: Air): RGB {
  const eye: Vec = [0, EARTH_R + OBSERVER_H, 0];
  const top = sphere(eye, view, TOP_R)!;
  const ground = sphere(eye, view, EARTH_R);
  const end = ground && ground[0] > 0 ? ground[0] : top[1];
  const mu = dot(view, sun);
  const phaseR = (3 / (16 * Math.PI)) * (1 + mu * mu);
  const g2 = MIE_G * MIE_G;
  const phaseM =
    ((3 / (8 * Math.PI)) * ((1 - g2) * (1 + mu * mu))) / ((2 + g2) * Math.pow(1 + g2 - 2 * MIE_G * mu, 1.5));
  const light: RGB = [0, 0, 0];
  let r = 0;
  let m = 0;
  let o = 0;
  // Samples close together near the eye, where the haze is, and further
  // apart higher up: a sight line along the horizon runs hundreds of km.
  for (let i = 0; i < VIEW_STEPS; i++) {
    const a = i / VIEW_STEPS;
    const b = (i + 1) / VIEW_STEPS;
    const ds = end * (b * b - a * a);
    const p = add(eye, view, end * ((a + b) / 2) ** 2);
    const [dr, dm, dz] = densities(p);
    r += dr * ds;
    m += dm * ds;
    o += dz * ds;
    const lit = toSun(p, sun);
    if (!lit) continue;
    const t = transmittance(air, r + lit[0], (m + lit[1]) / 1, o + lit[2]);
    for (let c = 0; c < 3; c++) {
      light[c]! +=
        t[c]! *
        (RAYLEIGH[c]! * dr * (phaseR + MULTIPLE_RAYLEIGH) + air.mie * MIE_ALBEDO * dm * (phaseM + MULTIPLE_MIE)) *
        ds;
    }
  }
  return light.map((x) => x * SUN) as RGB;
}

// The colour of a cloud deck: sunlight that reaches cloud height (reddened
// when the sun is low; none once the earth shades it), scattered back down.
function cloudLight(sun: Vec, air: Air, heightM: number, thickness: number): RGB {
  const p: Vec = [0, EARTH_R + heightM, 0];
  const lit = toSun(p, sun);
  const glow = CITY_GLOW.map((x) => x * 4) as RGB; // clouds reflect the city
  if (!lit) return glow;
  const t = transmittance(air, lit[0], lit[1], lit[2]);
  // By day the blue sky above a deck cancels most of the sun's warmth, so
  // it's grey; with the sun low, the sunlight's colour shows (sunset clouds).
  const grey = luminance(t);
  // A thick low deck hides most of a sunrise's colour.
  const warmth = Math.min(1, Math.max(0.1, 1 - 2.5 * sun[1])) * (1 - 0.7 * thickness);
  const tint = t.map((x) => grey + (x - grey) * warmth) as RGB;
  // Brighter with the sun higher; thick low cloud lets less through.
  const strength = SUN * 0.035 * (0.15 + Math.max(0, sun[1])) * (1 - 0.45 * thickness);
  return tint.map((x, i) => x * strength + glow[i]!) as RGB;
}

const mix = (a: RGB, b: RGB, f: number): RGB => a.map((x, i) => x * (1 - f) + b[i]! * f) as RGB;

// Linear light to an sRGB hex colour. The exposure curve compresses
// brightness, not each colour separately (which would grey the blue); a
// colour too bright to show goes toward white, as an overexposed sky does.
function hex(light: RGB, adaptation: number): string {
  const exposed = light.map((x) => x * EXPOSURE * adaptation) as RGB;
  const y = luminance(exposed);
  let rgb = (y > 0 ? exposed.map((x) => (x * (1 - Math.exp(-y))) / y) : [0, 0, 0]) as RGB;
  const over = Math.max(...rgb);
  if (over > 1) {
    // Keep the brightness, give up colour.
    const target = luminance(rgb);
    const scaled = rgb.map((x) => x / over) as RGB;
    const f = Math.min(1, (target - luminance(scaled)) / Math.max(1e-6, 1 - luminance(scaled)));
    rgb = scaled.map((x) => x + (1 - x) * f) as RGB;
  }
  const srgb = rgb.map((v) => {
    const s = v <= 0.0031308 ? 12.92 * v : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;
    return Math.round(Math.min(1, Math.max(0, s)) * 255);
  });
  return `#${srgb.map((x) => x.toString(16).padStart(2, "0")).join("")}`;
}

export type SkySquare = {
  label: string; // "Overhead", "NE", …
  elevation: number; // degrees above the horizon
  azimuth: number; // compass bearing
  color: string; // "#5b8bd0"
};

export type Sky = {
  at: number;
  sun: { elevation: number; azimuth: number };
  squares: SkySquare[];
};

// How high the compass tiles look, in degrees: low in the sky, where its
// colour changes most with the sun.
export const TILE_ELEVATION = 10;

export function sky(ms: number, lat: number, lon: number, weather: SkyInputs | null): Sky {
  const sunPos = sunPosition(ms, lat, lon);
  const sun = direction(sunPos.elevation, sunPos.azimuth);
  // Haze from visibility (Koschmieder: extinction = 3.912 / visibility),
  // less what clean air alone accounts for. Open-Meteo's visibility is a
  // model's estimate and runs low (40 km on a crisp day), so only half the
  // haze it implies is used.
  const visibilityM = weather?.visibilityFt ? weather.visibilityFt * 0.3048 : null;
  const air: Air = {
    mie: visibilityM ? Math.min(2e-3, Math.max(5e-6, 0.5 * (3.912 / visibilityM - RAYLEIGH[1]))) : DEFAULT_MIE,
  };
  const cover = Math.min(1, Math.max(0, (weather?.cloudCoverPct ?? 0) / 100));
  const low = Math.min(1, Math.max(0, (weather?.lowPct ?? 0) / 100));
  // Mostly low cloud: a lower, darker deck.
  const lowShare = cover > 0 ? Math.min(1, low / cover) : 0;
  const deck = cloudLight(sun, air, 2000 + 4000 * (1 - lowShare), lowShare);

  const glowAt = (view: Vec) => CITY_GLOW.map((x) => x * (1 + 2 * (1 - view[1]))) as RGB;
  const looking = (view: Vec): RGB => {
    const clear = add(clearSky(view, sun, air) as Vec, glowAt(view) as Vec) as RGB;
    // Near the horizon you look through more of the deck.
    return mix(clear, deck, Math.min(1, cover * (1 + 0.6 * (1 - view[1]))));
  };
  // Eyes adapt to the sky overhead, clouds and all.
  const adaptation = Math.min(
    MAX_ADAPTATION,
    Math.max(1, Math.sqrt(NOON_LUMINANCE / Math.max(1e-9, luminance(looking([0, 1, 0]))))),
  );

  const views: [string, number, number][] = [
    ["Overhead", 90, 0],
    ["NE", TILE_ELEVATION, 45],
    ["NW", TILE_ELEVATION, 315],
    ["SE", TILE_ELEVATION, 135],
    ["SW", TILE_ELEVATION, 225],
  ];
  const squares = views.map(([label, elevation, azimuth]) => {
    const color = hex(looking(direction(elevation, azimuth)), adaptation);
    return { label, elevation, azimuth: Math.round(azimuth), color };
  });
  return {
    at: ms,
    sun: { elevation: Math.round(sunPos.elevation * 10) / 10, azimuth: Math.round(sunPos.azimuth) },
    squares,
  };
}

// /live is polled by every viewer: the sky is worked out at most once a
// minute (and again when a new reading arrives).
let cache: { key: string; sky: Sky } | undefined;

export function skyNow(ms: number, lat: number, lon: number, weather: SkyInputs | null): Sky {
  const minute = Math.floor(ms / 60_000) * 60_000;
  const key = `${minute}:${weather?.observedAt ?? "none"}:${weather?.cloudCoverPct}:${weather?.visibilityFt}`;
  if (cache?.key !== key) cache = { key, sky: sky(minute, lat, lon, weather) };
  return cache.sky;
}
