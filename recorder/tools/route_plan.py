#!/usr/bin/env python3
"""Turns a route GPX into the recorder's route plan (JSON on stdout).

The GPX comes from the simulator's GPX download (website/src/Gpx.elm): a
waypoint per McDonald's in visiting order, each with a <mctrot:stop>
extension (mcdId, address, arrive, depart), and a track along the walk.
The API reads the JSON this prints (api/src/plan.ts). It runs at deploy
time, when NixOS builds the system (host/api.nix), so the API never
parses XML; `nix run .#route-plan -- some.gpx` runs it on the laptop.

A hand-written GPX works too, for a test walk: waypoints without the
extension get their position in the file as their id, and their <desc>
as their address (with a warning on stderr).

Python's standard library only.
"""

import json
import sys
import xml.etree.ElementTree as ET

GPX = "http://www.topografix.com/GPX/1/1"
MCTROT = "https://mctrot.nyc/gpx/1"  # Gpx.mctrotNamespace
NS = {"gpx": GPX, "mctrot": MCTROT}


def text(parent, path):
    if parent is None:
        return None
    node = parent.find(path, NS)
    value = node.text.strip() if node is not None and node.text else ""
    return value or None


def convert(path):
    root = ET.parse(path).getroot()
    if root.tag != f"{{{GPX}}}gpx":
        sys.exit(f"{path}: not a GPX 1.1 file (root element is {root.tag})")

    stores = []
    for i, wpt in enumerate(root.findall("gpx:wpt", NS), start=1):
        ext = wpt.find("gpx:extensions/mctrot:stop", NS)
        if ext is None:
            print(f"{path}: waypoint {i} has no <mctrot:stop>; id {i}, address from <desc>",
                  file=sys.stderr)
        stores.append({
            "id": text(ext, "mctrot:mcdId") or str(i),
            "name": text(wpt, "gpx:name") or f"Stop {i}",
            "address": text(ext, "mctrot:address") or text(wpt, "gpx:desc") or "",
            "lat": float(wpt.get("lat")),
            "lon": float(wpt.get("lon")),
            "arrive": text(ext, "mctrot:arrive"),
            "depart": text(ext, "mctrot:depart"),
        })

    if not stores:
        sys.exit(f"{path}: no waypoints, so no stores to visit")
    ids = [s["id"] for s in stores]
    duplicates = sorted({i for i in ids if ids.count(i) > 1})
    if duplicates:
        sys.exit(f"{path}: store ids appear twice: {', '.join(duplicates)}")

    track = [
        [float(p.get("lat")), float(p.get("lon"))]
        for p in root.iterfind("gpx:trk/gpx:trkseg/gpx:trkpt", NS)
    ]
    return {"stores": stores, "track": track}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: route_plan.py ROUTE.gpx > route-plan.json")
    plan = convert(sys.argv[1])
    json.dump(plan, sys.stdout, indent=2)
    sys.stdout.write("\n")
    print(f"{len(plan['stores'])} stores, {len(plan['track'])} track points", file=sys.stderr)
