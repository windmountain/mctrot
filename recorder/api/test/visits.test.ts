import assert from "node:assert/strict";
import { test } from "node:test";
import { matchVisits, metres, positionAt, type Where } from "../src/visits.ts";
import { PLAN } from "./helpers.ts";

const [A, B, C] = PLAN.stores as [typeof PLAN.stores[0], typeof PLAN.stores[0], typeof PLAN.stores[0]];
const T = Date.parse("2026-12-05T12:00:00Z");
const min = 60_000;
const at = (p: { lat: number; lon: number }): Where => ({ kind: "at", at: p });
// A spot `m` metres north of a store.
const north = (p: { lat: number; lon: number }, m: number) => ({ lat: p.lat + m / 111_320, lon: p.lon });

test("test stores are far enough apart to be unambiguous", () => {
  assert.ok(metres(A, B) > 300 && metres(A, C) > 300 && metres(B, C) > 300);
});

test("a tap at a store matches it", () => {
  const visits = matchVisits([T], PLAN.stores, () => at(north(A, 30)));
  assert.deepEqual(visits, [{ tapTs: T, status: "matched", storeId: "a", distanceM: 30 }]);
});

test("taps match in time order, each to a different store", () => {
  const where = (ts: number) => at(ts === T ? A : B);
  const visits = matchVisits([T + 20 * min, T], PLAN.stores, where);
  assert.deepEqual(visits.map((v) => v.status === "matched" && v.storeId), ["a", "b"]);
});

test("two stores close together: the nearest unclaimed one wins", () => {
  // Two stores 100 m apart; I tap twice standing between them, nearer X.
  const X = { id: "x", name: "X", address: "", lat: 40.75, lon: -73.99 };
  const Y = { id: "y", name: "Y", address: "", lat: 40.75 + 100 / 111_320, lon: -73.99 };
  const spot = north(X, 30);
  const visits = matchVisits([T, T + 10 * min], [X, Y], () => at(spot));
  assert.deepEqual(visits.map((v) => v.status === "matched" && v.storeId), ["x", "y"]);
});

test("no store within 150 m: unmatched", () => {
  const visits = matchVisits([T], PLAN.stores, () => at(north(A, 200)));
  assert.equal(visits[0]?.status, "unmatched");
});

test("a store already claimed isn't matched again", () => {
  const visits = matchVisits([T, T + 10 * min], PLAN.stores, () => at(A));
  assert.deepEqual(visits.map((v) => v.status), ["matched", "unmatched"]);
});

test("taps within 2 minutes are one visit", () => {
  const visits = matchVisits([T, T + 30_000, T + 90_000], PLAN.stores, () => at(A));
  assert.equal(visits.length, 1);
  assert.equal(visits[0]?.tapTs, T);
});

test("waiting for GPS: a pending tap doesn't claim its store", () => {
  const where = (ts: number): Where => (ts === T ? { kind: "pending" } : at(A));
  const visits = matchVisits([T, T + 10 * min], PLAN.stores, where);
  assert.deepEqual(visits.map((v) => v.status), ["pending", "matched"]);
});

test("positionAt interpolates between the fixes around the tap", () => {
  const w = positionAt({ ts: T - min, lat: 40, lon: -74 }, { ts: T + min, lat: 40.002, lon: -73.998 }, T);
  assert.equal(w.kind, "at");
  if (w.kind === "at") {
    assert.ok(Math.abs(w.at.lat - 40.001) < 1e-9 && Math.abs(w.at.lon + 73.999) < 1e-9);
  }
});

test("positionAt: nothing after the tap yet, last fix recent: use it", () => {
  const w = positionAt({ ts: T - 30_000, lat: 40, lon: -74 }, undefined, T);
  assert.deepEqual(w, { kind: "at", at: { ts: T - 30_000, lat: 40, lon: -74 } });
});

test("positionAt: nothing after the tap yet, last fix old: pending", () => {
  assert.deepEqual(positionAt({ ts: T - 10 * min, lat: 40, lon: -74 }, undefined, T), { kind: "pending" });
  assert.deepEqual(positionAt(undefined, undefined, T), { kind: "pending" });
});

test("positionAt: a long gap with no fix near the tap: no position", () => {
  const w = positionAt({ ts: T - 15 * min, lat: 40, lon: -74 }, { ts: T + 15 * min, lat: 40, lon: -74 }, T);
  assert.deepEqual(w, { kind: "none" });
});

test("positionAt: a long gap, but a fix just after the tap: use it", () => {
  const w = positionAt({ ts: T - 30 * min, lat: 39, lon: -74 }, { ts: T + 60_000, lat: 40, lon: -74 }, T);
  assert.deepEqual(w, { kind: "at", at: { ts: T + 60_000, lat: 40, lon: -74 } });
});
