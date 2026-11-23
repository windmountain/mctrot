// The route plan: route-plan.json, made from route-plan.gpx by the
// server's tools/route_plan.py (kept here as made, since the tool is gone).
import { readFileSync } from "node:fs";

export type Store = {
  id: string;
  name: string;
  address: string;
  lat: number;
  lon: number;
  arrive: string | null; // ISO time, planned
  depart: string | null;
};

export type RoutePlan = { stores: Store[]; track: [number, number][] };

export function loadPlan(path: string): RoutePlan {
  const plan = JSON.parse(readFileSync(path, "utf8")) as RoutePlan;
  if (new Set(plan.stores.map((s) => s.id)).size !== plan.stores.length) throw new Error("store ids must be unique");
  return { stores: plan.stores, track: plan.track ?? [] };
}
