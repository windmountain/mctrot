// Visits: I tap "Visit" at each McDonald's, and the tap is only a time.
// Which store it was is worked out here, from the GPS track and the route
// plan, every time it's asked for: GPS is weakest exactly when I tap
// (indoors), and the points around a tap may arrive minutes later from
// Overland's queue, so nothing about a match is ever stored.
// See recorder/DESIGN.md, "Visits".
import type { Db } from "./db.ts";
import type { Store } from "./plan.ts";

// Guesses, to tune on a test walk.
export const MATCH_RADIUS_M = 150; // tap position to store
export const DOUBLE_TAP_MS = 2 * 60_000; // taps closer than this are one visit
export const MAX_GAP_MS = 10 * 60_000; // interpolate across GPS gaps up to this
export const NEAR_MS = 2 * 60_000; // or use one fix this close to the tap

export type LatLon = { lat: number; lon: number };
type Fix = LatLon & { ts: number };

export type Visit =
  | { tapTs: number; status: "matched"; storeId: string; distanceM: number }
  | { tapTs: number; status: "pending" } // waiting for GPS after the tap
  | { tapTs: number; status: "unmatched" }; // no store near, or no GPS near

export function tapsBetween(db: Db, from: number, to: number): number[] {
  return (db.prepare("select ts from visit_taps where ts >= ? and ts <= ? order by ts").all(from, to) as { ts: number }[]).map(
    (r) => r.ts,
  );
}

export type Where = { kind: "at"; at: LatLon } | { kind: "pending" } | { kind: "none" };

// Where I was at time `ts`, from the fixes just before and after it.
export function positionAt(before: Fix | undefined, after: Fix | undefined, ts: number): Where {
  if (before && after && after.ts - before.ts <= MAX_GAP_MS) {
    const f = after.ts === before.ts ? 0 : (ts - before.ts) / (after.ts - before.ts);
    return {
      kind: "at",
      at: { lat: before.lat + f * (after.lat - before.lat), lon: before.lon + f * (after.lon - before.lon) },
    };
  }
  if (before && ts - before.ts <= NEAR_MS) return { kind: "at", at: before };
  if (after && after.ts - ts <= NEAR_MS) return { kind: "at", at: after };
  // Nothing recorded after the tap yet: Overland may still be catching up.
  if (!after) return { kind: "pending" };
  return { kind: "none" };
}

export function positionFromDb(db: Db, ts: number): Where {
  const before = db
    .prepare("select ts, lat, lon from points where ts <= ? order by ts desc limit 1")
    .get(ts) as Fix | undefined;
  const after = db
    .prepare("select ts, lat, lon from points where ts >= ? order by ts limit 1")
    .get(ts) as Fix | undefined;
  return positionAt(before, after, ts);
}

export function metres(a: LatLon, b: LatLon): number {
  const rad = Math.PI / 180;
  const h =
    Math.sin(((b.lat - a.lat) * rad) / 2) ** 2 +
    Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(((b.lon - a.lon) * rad) / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.sqrt(h));
}

// Taps in time order; each takes the nearest store within the radius that
// an earlier tap hasn't claimed. A pending tap claims nothing yet.
export function matchVisits(
  taps: number[],
  stores: Pick<Store, "id" | "lat" | "lon">[],
  where: (ts: number) => Where,
): Visit[] {
  const sorted = [...taps].sort((a, b) => a - b);
  const claimed = new Set<string>();
  const visits: Visit[] = [];
  let lastKept = -Infinity;
  for (const tapTs of sorted) {
    if (tapTs - lastKept < DOUBLE_TAP_MS) continue;
    lastKept = tapTs;
    const w = where(tapTs);
    if (w.kind !== "at") {
      visits.push({ tapTs, status: w.kind === "pending" ? "pending" : "unmatched" });
      continue;
    }
    let best: { store: Pick<Store, "id" | "lat" | "lon">; d: number } | undefined;
    for (const store of stores) {
      if (claimed.has(store.id)) continue;
      const d = metres(w.at, store);
      if (d <= MATCH_RADIUS_M && (!best || d < best.d)) best = { store, d };
    }
    if (best) {
      claimed.add(best.store.id);
      visits.push({ tapTs, status: "matched", storeId: best.store.id, distanceM: Math.round(best.d) });
    } else {
      visits.push({ tapTs, status: "unmatched" });
    }
  }
  return visits;
}
