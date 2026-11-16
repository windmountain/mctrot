import { readFileSync } from "node:fs";
import { z } from "zod";

// The route plan: the stores Visit taps are matched against. It starts as
// the simulator's GPX download and is converted to this JSON when the
// system is built (tools/route_plan.py, host/api.nix), so the API never
// parses XML. Without one (MCTROT_ROUTE_PLAN unset) there are no stores.
export const Store = z.object({
  id: z.string().min(1),
  name: z.string(),
  address: z.string(),
  lat: z.number().min(-90).max(90),
  lon: z.number().min(-180).max(180),
  // Planned times, UTC ISO; null in a hand-written plan.
  arrive: z.string().nullable().default(null),
  depart: z.string().nullable().default(null),
});

export const RoutePlan = z.object({
  stores: z.array(Store).refine(
    (stores) => new Set(stores.map((s) => s.id)).size === stores.length,
    "store ids must be unique",
  ),
  // The walking route as [lat, lon] pairs, for mileage later (step 12).
  track: z.array(z.tuple([z.number(), z.number()])).default([]),
});

export type Store = z.infer<typeof Store>;
export type RoutePlan = z.infer<typeof RoutePlan>;

export const NO_PLAN: RoutePlan = { stores: [], track: [] };

// Throws on a bad file: better not to start than to match against nonsense.
export function loadPlan(path: string | undefined): RoutePlan {
  if (path === undefined) return NO_PLAN;
  return RoutePlan.parse(JSON.parse(readFileSync(path, "utf8")));
}
