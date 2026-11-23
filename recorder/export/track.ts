// The path I've walked, for /live's map: the GPS points, thinned out so a
// whole day (tens of thousands of fixes) fits in a small response.
//
// - Fixes worse than MAX_ACCURACY_M (indoors, in a McDonald's) are dropped:
//   they scatter around the true spot and draw spikes.
// - A gap longer than GAP_MS (signal lost, or dislocated test data) breaks
//   the path into separate segments instead of drawing a straight line.
// - Each segment is simplified (Douglas–Peucker) to within TOLERANCE_M of
//   the recorded path, which keeps every corner but drops the points along
//   straight stretches.
//
// First guesses, to tune once Overland's settings are worked out.

export const MAX_ACCURACY_M = 50;
export const GAP_MS = 10 * 60_000;
// The map is about 30 m per screen pixel on a phone: 10 m is invisible.
export const TOLERANCE_M = 10;
// With no attempt yet, the map shows the last day's walking.
export const NO_ATTEMPT_WINDOW_MS = 24 * 3_600_000;

type Fix = { ts: number; lat: number; lon: number };
export type Segment = [lat: number, lon: number][];

// Metres east and north of a fix, near enough for a few kilometres.
const M_PER_DEG_LAT = 111_320;
function toXY(f: Fix, lat0: number): [number, number] {
  return [f.lon * M_PER_DEG_LAT * Math.cos((lat0 * Math.PI) / 180), f.lat * M_PER_DEG_LAT];
}

// Distance from p to the segment a–b, all in metres.
function offset(p: [number, number], a: [number, number], b: [number, number]): number {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const len2 = dx * dx + dy * dy;
  const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2));
  return Math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}

// Douglas–Peucker, with an explicit stack: a long straight walk would
// otherwise recurse once per point.
export function simplify(fixes: Fix[], tolerance = TOLERANCE_M): Fix[] {
  if (fixes.length <= 2) return fixes;
  const lat0 = fixes[0]!.lat;
  const xy = fixes.map((f) => toXY(f, lat0));
  const keep = new Uint8Array(fixes.length);
  keep[0] = 1;
  keep[fixes.length - 1] = 1;
  const stack: [number, number][] = [[0, fixes.length - 1]];
  while (stack.length) {
    const [first, last] = stack.pop()!;
    let worst = -1;
    let worstD = tolerance;
    for (let i = first + 1; i < last; i++) {
      const d = offset(xy[i]!, xy[first]!, xy[last]!);
      if (d > worstD) {
        worst = i;
        worstD = d;
      }
    }
    if (worst !== -1) {
      keep[worst] = 1;
      stack.push([first, worst], [worst, last]);
    }
  }
  return fixes.filter((_, i) => keep[i]);
}

export function segments(fixes: Fix[], gapMs = GAP_MS, tolerance = TOLERANCE_M): Segment[] {
  const out: Segment[] = [];
  let current: Fix[] = [];
  const finish = () => {
    // A lone fix draws nothing.
    if (current.length >= 2) {
      out.push(simplify(current, tolerance).map((f) => [round(f.lat), round(f.lon)]));
    }
    current = [];
  };
  for (const f of fixes) {
    const prev = current[current.length - 1];
    if (prev && f.ts - prev.ts > gapMs) finish();
    current.push(f);
  }
  finish();
  return out;
}

// Six decimals is about 10 cm: plenty, and it keeps the JSON small.
const round = (deg: number) => Math.round(deg * 1e6) / 1e6;
