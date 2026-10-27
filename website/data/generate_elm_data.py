#!/usr/bin/env python3
"""Turns the simulator's input data (written here by
scripts/export_simulator_data.py) into Elm and CSS:

  - mctrot_map.svg -> ../src/MctrotMapData.elm and ../css/mctrot-map.css
  - mcd_locations.csv, mcd_hours.csv, route_summary.csv -> ../src/McdData.elm

mctrot_map.svg is the source of truth for the map (a real Manhattan silhouette, every
McDonald's location, and a real-street routing layer where each road
segment's `class` attribute lists every location-pair whose shortest route
crosses it). The source SVG cuts that routing layer into one `<path>` per
road-network node-to-node segment (2867 of them), but many neighboring
segments -- ones that just happen to sit between the same two intersections
along a street with no route ever forking there -- carry the exact same
`lX-lY` membership. Since SVG lets one `<path>` hold several disconnected
`M ... L ...` subpaths (rendered identically to separate elements, same
stroke/class for all of them), `merge_edges` combines every group of edges
that share an identical membership set into a single multi-subpath entry --
2867 edges collapse to ~620, with no change to what's drawn or how the
`data-active` CSS highlighting behaves.

This script transcodes the (merged) SVG into:

  - ../src/MctrotMapData.elm: pure Elm data (no logic) that Simulator.elm renders.
  - ../css/mctrot-map.css: base layer styles plus one CSS rule per possible
    location-pair, so Simulator.elm only ever needs to update a single
    `data-active` attribute at runtime to drive route highlighting.

McdData.elm holds each location's nickname, street address, its weekly open/closed windows
(see `week_windows`), and the walking-distance matrix.

Re-run this whenever any of those inputs change.
"""
import csv
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
SVG_PATH = HERE / "mctrot_map.svg"
LOCATIONS_CSV = HERE / "mcd_locations.csv"
HOURS_CSV = HERE / "mcd_hours.csv"
ROUTES_CSV = HERE / "route_summary.csv"
ELM_OUT = HERE.parent / "src" / "MctrotMapData.elm"
MCD_ELM_OUT = HERE.parent / "src" / "McdData.elm"
CSS_OUT = HERE.parent / "css" / "mctrot-map.css"

WEEK = 7 * 24 * 60

NS = "{http://www.w3.org/2000/svg}"


def elm_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    root = ET.parse(SVG_PATH).getroot()

    view_box = root.get("viewBox")

    borough_path_el = root.find(f".//{NS}g[@id='layer-borough']/{NS}path")
    borough_d = borough_path_el.get("d")

    locations = []
    for circle in root.findall(f".//{NS}g[@id='layer-locations']/{NS}circle"):
        mcd_id = int(circle.get("data-mcd-id"))
        cx = float(circle.get("cx"))
        cy = float(circle.get("cy"))
        locations.append((mcd_id, cx, cy))
    locations.sort(key=lambda t: t[0])
    assert locations, "no location circles found"

    edges = []
    for path in root.findall(f".//{NS}g[@id='layer-routes']/{NS}path"):
        edges.append((path.get("class"), path.get("d")))
    assert edges, "no route-edge paths found"

    merged_edges = merge_edges(edges)

    write_elm(view_box, borough_d, locations, merged_edges)
    write_css([mcd_id for mcd_id, _, _ in locations])

    print(
        f"wrote {ELM_OUT} ({len(locations)} locations, "
        f"{len(edges)} route edges merged into {len(merged_edges)})"
    )
    n = len(locations)
    print(f"wrote {CSS_OUT} ({n * (n - 1) // 2} highlight rules)")

    mcd_ids = [mcd_id for mcd_id, _, _ in locations]
    write_mcd_elm(mcd_ids)
    print(f"wrote {MCD_ELM_OUT} ({len(mcd_ids)} locations)")


def week_windows(day_ranges):
    """Turns seven per-day (open_minute, close_minute) ranges (Monday first;
    close may exceed 1440 when a day runs past midnight) into merged
    minutes-since-Monday-00:00 open windows within one repeating week,
    splitting any that cross the Sunday/Monday seam, plus their complement as
    closed windows.
    """
    spans = []
    for weekday, (open_minute, close_minute) in enumerate(day_ranges):
        start = weekday * 1440 + open_minute
        end = weekday * 1440 + close_minute
        if end > WEEK:
            spans.append((start, WEEK))
            spans.append((0, end - WEEK))
        elif end > start:
            spans.append((start, end))

    open_windows = []
    for start, end in sorted(spans):
        if open_windows and start <= open_windows[-1][1]:
            open_windows[-1] = (open_windows[-1][0], max(open_windows[-1][1], end))
        else:
            open_windows.append((start, end))

    closed_windows = []
    cursor = 0
    for start, end in open_windows:
        if start > cursor:
            closed_windows.append((cursor, start))
        cursor = end
    if cursor < WEEK:
        closed_windows.append((cursor, WEEK))

    return open_windows, closed_windows


def write_mcd_elm(mcd_ids):
    with open(LOCATIONS_CSV, newline="") as f:
        rows = list(csv.DictReader(f))
    nicknames = {int(r["id"]): r["nickname"] for r in rows}
    # Just the street line ("160 Broadway"), not ", New York, NY 10038".
    addresses = {int(r["id"]): r["address"].split(",")[0].strip() for r in rows}

    day_ranges = {}
    with open(HOURS_CSV, newline="") as f:
        for r in csv.DictReader(f):
            day_ranges.setdefault(int(r["mcd_id"]), [None] * 7)[int(r["weekday"])] = (
                int(r["open_minute"]),
                int(r["close_minute"]),
            )

    distances = {}
    with open(ROUTES_CSV, newline="") as f:
        for r in csv.DictReader(f):
            a, b = int(r["from_mcd_id"]), int(r["to_mcd_id"])
            distances[(a, b)] = distances[(b, a)] = round(float(r["distance_meters"]))

    assert sorted(nicknames) == mcd_ids, "mcd_locations.csv ids don't match the map's locations"
    assert sorted(day_ranges) == mcd_ids, "mcd_hours.csv ids don't match the map's locations"

    def windows_elm(windows):
        if not windows:
            return "[]"
        return "[ " + ", ".join(f"( {s}, {e} )" for s, e in windows) + " ]"

    city_lines = []
    for mcd_id in mcd_ids:
        ranges = day_ranges[mcd_id]
        assert None not in ranges, f"mcd {mcd_id} is missing hours for some weekday"
        open_windows, closed_windows = week_windows(ranges)
        city_lines.append(
            f"City {elm_string(nicknames[mcd_id])} {elm_string(addresses[mcd_id])} {windows_elm(open_windows)} {windows_elm(closed_windows)}"
        )

    row_lines = []
    for a in mcd_ids:
        row = ", ".join(str(0 if a == b else distances[(a, b)]) for b in mcd_ids)
        row_lines.append(f"Array.fromList [ {row} ]")

    newline_comma = "\n        , "
    elm_source = f"""module McdData exposing (City, cities, distanceMeters)

{{-| Generated by website/data/generate_elm_data.py from website/data/mcd_locations.csv,
mcd_hours.csv and route_summary.csv. Do not hand-edit; re-run
scripts/export_simulator_data.py (or just the generator) instead.
-}}

import Array exposing (Array)


{{-| `address` is the street line only (e.g. "160 Broadway").
`openWindows`/`closedWindows` are minutes-since-Monday-00:00 in a
repeating 7-day ({WEEK}-minute) week, from the database's `mcd_hours` view --
adjacent open days merged together, and any window that crosses the
Sunday/Monday seam split. Always-open locations get a single `( 0, {WEEK} )`
window and no closed windows at all. The two lists are complements of each
other within the week; both are kept so neither `waitForCity` nor the view
has to compute a complement at runtime.
-}}
type alias City =
    {{ name : String
    , address : String
    , openWindows : List ( Int, Int )
    , closedWindows : List ( Int, Int )
    }}


{{-| One entry per location, in ascending `mcd_id` order (the same order as
`MctrotMapData.mcdIds`).
-}}
cities : Array City
cities =
    Array.fromList
        [ {newline_comma.join(city_lines)}
        ]


{{-| Walking distance in whole meters between every pair of locations, same
index order as `cities` (symmetric, zero on the diagonal). This is *not* a
travel time -- Simulator's `travelTime` converts it to minutes.
-}}
distanceMeters : Array (Array Int)
distanceMeters =
    Array.fromList
        [ {newline_comma.join(row_lines)}
        ]
"""
    MCD_ELM_OUT.write_text(elm_source)


def merge_edges(edges):
    """Combines edges that share an identical `lX-lY` membership set into one
    multi-subpath entry each (see the module docstring for why this is safe).
    """
    groups = {}
    order = []
    for classes, d in edges:
        tokens = tuple(sorted(classes.split()[1:]))
        if tokens not in groups:
            groups[tokens] = []
            order.append(tokens)
        groups[tokens].append(d)

    return [
        ("route-edge " + " ".join(tokens), " ".join(groups[tokens]))
        for tokens in order
    ]


def route_view_box(view_box, locations, edges):
    """`view_box` narrowed horizontally to just the locations and route paths
    (full height kept), for the simulator's "superstretch" map."""
    xs = [cx for _, cx, _ in locations]
    for _, d in edges:
        tokens = [t for t in d.split() if t not in ("M", "L")]
        xs.extend(float(t) for t in tokens[0::2])
    _, min_y, _, height = view_box.split()
    return f"{min(xs)} {min_y} {round(max(xs) - min(xs), 1)} {height}"


def write_elm(view_box, borough_d, locations, edges):
    ids_list = ", ".join(str(mcd_id) for mcd_id, _, _ in locations)
    coords_list = ", ".join(f"( {cx}, {cy} )" for _, cx, cy in locations)
    edges_list = ",\n    ".join(
        f"{{ classes = {elm_string(classes)}, d = {elm_string(d)} }}"
        for classes, d in edges
    )

    elm_source = f"""module MctrotMapData exposing (boroughPath, locationCoords, mapViewBox, mcdIds, routeEdges, routeViewBox)

{{-| Generated by website/data/generate_elm_data.py from website/data/mctrot_map.svg.
Do not hand-edit; re-run the script instead.
-}}

import Array exposing (Array)


mapViewBox : String
mapViewBox =
    {elm_string(view_box)}


{{-| `mapViewBox` narrowed horizontally to the westernmost and easternmost
point of any location or route path (see generate_elm_data.py's
`route_view_box`).
-}}
routeViewBox : String
routeViewBox =
    {elm_string(route_view_box(view_box, locations, edges))}


{{-| The single Manhattan borough silhouette path, verbatim from the source SVG.
-}}
boroughPath : String
boroughPath =
    {elm_string(borough_d)}


{{-| The real `mcd_id` (see website/data/mcd_locations.csv) for each stop, in the
same ascending order as Simulator's `cities` array -- so `Array.get i mcdIds`
gives the id for city index `i`.
-}}
mcdIds : Array Int
mcdIds =
    Array.fromList [ {ids_list} ]


{{-| Real (x, y) coordinates for each stop, same index order as `mcdIds` and
`cities`.
-}}
locationCoords : Array ( Float, Float )
locationCoords =
    Array.fromList [ {coords_list} ]


{{-| Every real-street road segment in the routing layer, with adjacent
segments that share an identical route membership already merged into one
entry (see generate_elm_data.py's `merge_edges`) -- `d` may hold several
disconnected `M ... L ...` subpaths, which render exactly like separate
`<path>` elements would. Each `classes` string includes every `lX-lY` token
(X, Y are `mcdIds` values) whose shortest route crosses that segment -- see
mctrot-map.css for the `[data-active~="lX-lY"] .lX-lY` highlight rules these
tokens drive.
-}}
routeEdges : List {{ classes : String, d : String }}
routeEdges =
    [ {edges_list}
    ]
"""
    ELM_OUT.write_text(elm_source)


def write_css(mcd_ids):
    lines = [
        # The map is stretched non-uniformly to fill its box, so every stroke
        # is non-scaling and sized in screen pixels. Locations are zero-length
        # round-capped paths, which stay circular under the stretch.
        ".borough { fill: #000; stroke: #999; stroke-width: 0.5px; vector-effect: non-scaling-stroke; }",
        ".route-edge { fill: none; stroke: #ccc; stroke-width: 1px; vector-effect: non-scaling-stroke; transition: stroke 150ms ease, stroke-width 150ms ease; }",
        ".location { fill: none; stroke: #FF0000; stroke-width: 5px; stroke-linecap: round; vector-effect: non-scaling-stroke; }",
        "",
    ]
    n = len(mcd_ids)
    for i in range(n):
        for j in range(i + 1, n):
            token = f"l{mcd_ids[i]}-l{mcd_ids[j]}"
            lines.append(
                f'[data-active~="{token}"] .{token} {{ stroke: #FFD100; stroke-width: 8px; }}'
            )
    CSS_OUT.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
