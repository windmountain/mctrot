// The weather's place and wording: the server's weather.ts, without its
// fetching (Open-Meteo) and reading, which the export does itself.

// One point for all of the walk's weather and sun times: the usual centre
// of Manhattan, in Central Park near 81st Street.
export const WEATHER_POINT = { name: "Central Manhattan", lat: 40.7831, lon: -73.9712 };

// What the sky model needs from the latest reading, from its raw reply:
// cloud cover by height (0–100) and visibility (feet). Null fields when the
// reading predates them or Open-Meteo left them out.
export type SkyInputs = {
  observedAt: number;
  cloudCoverPct: number | null;
  lowPct: number | null;
  midPct: number | null;
  highPct: number | null;
  visibilityFt: number | null;
};

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
