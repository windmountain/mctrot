// Sunrise, sunset and the twilights for a day in New York, worked out from
// the date and the place (no network), with the formulas of NOAA's solar
// calculator (from Meeus, Astronomical Algorithms). Each time is solved by
// repeating the calculation with the sun's position at the previous
// answer, which brings it within about a minute of published tables.
//
// Each twilight starts or ends when the sun's centre is that far below the
// horizon: civil 6°, nautical 12°, astronomical 18°. Sunrise and sunset
// use −0.833°, which allows for the sun's radius and the air bending its
// light.

const RAD = Math.PI / 180;
const MINUTE = 60_000;

export type SunTimes = {
  date: string; // the New York calendar day, "2026-11-21"
  astronomicalDawn: number | null; // ms since epoch; null if it doesn't happen that day
  nauticalDawn: number | null;
  civilDawn: number | null;
  sunrise: number | null;
  solarNoon: number;
  sunset: number | null;
  civilDusk: number | null;
  nauticalDusk: number | null;
  astronomicalDusk: number | null;
};

// The calendar day ("YYYY-MM-DD") in New York at a moment.
export function newYorkDate(ms: number): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York" }).format(ms);
}

// The sun's declination (radians) and the equation of time (minutes).
function sunAt(ms: number): { dec: number; eot: number } {
  const t = (ms / 86_400_000 + 2440587.5 - 2451545) / 36525; // Julian centuries since J2000
  const l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)) % 360; // mean longitude
  const m = 357.52911 + t * (35999.05029 - 0.0001537 * t); // mean anomaly
  const e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t); // orbit's eccentricity
  const centre =
    Math.sin(m * RAD) * (1.914602 - t * (0.004817 + 0.000014 * t)) +
    Math.sin(2 * m * RAD) * (0.019993 - 0.000101 * t) +
    Math.sin(3 * m * RAD) * 0.000289;
  const omega = 125.04 - 1934.136 * t;
  const apparent = l0 + centre - 0.00569 - 0.00478 * Math.sin(omega * RAD);
  const meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60;
  const obliquity = meanObliquity + 0.00256 * Math.cos(omega * RAD);
  const dec = Math.asin(Math.sin(obliquity * RAD) * Math.sin(apparent * RAD));
  const y = Math.tan((obliquity / 2) * RAD) ** 2;
  const eot =
    (4 / RAD) *
    (y * Math.sin(2 * l0 * RAD) -
      2 * e * Math.sin(m * RAD) +
      4 * e * y * Math.sin(m * RAD) * Math.cos(2 * l0 * RAD) -
      0.5 * y * y * Math.sin(4 * l0 * RAD) -
      1.25 * e * e * Math.sin(2 * m * RAD));
  return { dec, eot };
}

// When the sun's centre is `altitude` degrees above the horizon, rising or
// setting, on the UTC day starting at `midnightUtc`; null if it never is.
function crossing(midnightUtc: number, lat: number, lon: number, altitude: number, rising: boolean): number | null {
  let ms = midnightUtc + (720 - 4 * lon) * MINUTE;
  for (let i = 0; i < 5; i++) {
    const { dec, eot } = sunAt(ms);
    const cosH =
      (Math.sin(altitude * RAD) - Math.sin(lat * RAD) * Math.sin(dec)) / (Math.cos(lat * RAD) * Math.cos(dec));
    if (cosH < -1 || cosH > 1) return null;
    const h = Math.acos(cosH) / RAD;
    ms = midnightUtc + (720 - 4 * (lon + (rising ? h : -h)) - eot) * MINUTE;
  }
  return Math.round(ms);
}

function solarNoon(midnightUtc: number, lon: number): number {
  let ms = midnightUtc + (720 - 4 * lon) * MINUTE;
  for (let i = 0; i < 3; i++) ms = midnightUtc + (720 - 4 * lon - sunAt(ms).eot) * MINUTE;
  return Math.round(ms);
}

export function sunTimes(date: string, lat: number, lon: number): SunTimes {
  // Times count in minutes from midnight UTC of the same date; a late dusk
  // simply runs past 1440 (June's astronomical dusk is about 02:40 UTC the
  // next day), so every event lands on the New York day asked for.
  const midnight = Date.parse(`${date}T00:00:00Z`);
  const at = (altitude: number, rising: boolean) => crossing(midnight, lat, lon, altitude, rising);
  return {
    date,
    astronomicalDawn: at(-18, true),
    nauticalDawn: at(-12, true),
    civilDawn: at(-6, true),
    sunrise: at(-0.833, true),
    solarNoon: solarNoon(midnight, lon),
    sunset: at(-0.833, false),
    civilDusk: at(-6, false),
    nauticalDusk: at(-12, false),
    astronomicalDusk: at(-18, false),
  };
}
