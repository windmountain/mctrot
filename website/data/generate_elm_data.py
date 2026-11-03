#!/usr/bin/env python3
"""Turns the simulator's input data (written here by
scripts/export_simulator_data.py) into Elm and CSS:

  - mctrot_map.svg -> ../src/MctrotMapData.elm and ../css/mctrot-map.css
  - mcd_locations.csv, mcd_hours.csv, route_summary.csv -> ../src/McdData.elm
  - route_legs.csv -> ../geo/route-legs.json (fetched by the simulator only
    when it exports a GPX file, so it stays out of the page's script)

mctrot_map.svg is the source of truth for the map: a real Manhattan
silhouette, every McDonald's location, a layer of every road segment any
route uses (one `<path>` per road-network node-to-node segment), and a layer
with one continuous `<path>` per location pair, walking that pair's shortest
route. The simulator draws the road segments as one grey multi-subpath
`<path>` (SVG renders the subpaths exactly like separate elements), and the
current tour's legs over it, each as a single stroke so its corners join
cleanly.

This script transcodes the SVG into:

  - ../src/MctrotMapData.elm: pure Elm data (no logic) that Simulator.elm renders.
  - ../css/mctrot-map.css: the map layers' styles.

McdData.elm holds each location's nickname, street address, coordinates, its weekly open/closed windows
(see `week_windows`), and the walking-distance matrix.

Re-run this whenever any of those inputs change.
"""
import csv
import json
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
SVG_PATH = HERE / "mctrot_map.svg"
LOCATIONS_CSV = HERE / "mcd_locations.csv"
HOURS_CSV = HERE / "mcd_hours.csv"
ROUTES_CSV = HERE / "route_summary.csv"
LEGS_CSV = HERE / "route_legs.csv"
LEGS_OUT = HERE.parent / "geo" / "route-legs.json"
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

    edges = [path.get("d") for path in root.findall(f".//{NS}g[@id='layer-routes']/{NS}path")]
    assert edges, "no route-edge paths found"

    legs = {}
    for path in root.findall(f".//{NS}g[@id='layer-legs']/{NS}path"):
        lo, hi = int(path.get("data-lo")), int(path.get("data-hi"))
        assert lo < hi, f"leg {lo}-{hi} isn't keyed lower mcd_id first"
        legs[(lo, hi)] = path.get("d")

    mcd_ids = [mcd_id for mcd_id, _, _ in locations]
    n = len(mcd_ids)
    assert len(legs) == n * (n - 1) // 2 and all(
        (a, b) in legs for i, a in enumerate(mcd_ids) for b in mcd_ids[i + 1 :]
    ), "mctrot_map.svg's layer-legs doesn't cover every location pair"

    write_elm(view_box, borough_d, locations, edges, legs)
    write_css()

    print(f"wrote {ELM_OUT} ({len(locations)} locations, {len(edges)} route edges, {len(legs)} legs)")
    print(f"wrote {CSS_OUT}")

    write_mcd_elm(mcd_ids)
    print(f"wrote {MCD_ELM_OUT} ({len(mcd_ids)} locations)")

    n_legs = write_legs_json(mcd_ids)
    print(f"wrote {LEGS_OUT} ({n_legs} legs)")


def write_legs_json(mcd_ids):
    """`{"lo-hi": polyline}`, keyed by real mcd_ids with lo < hi; each
    polyline runs from lo to hi (see Simulator's GPX export)."""
    with open(LEGS_CSV, newline="") as f:
        legs = {f"{r['lo_mcd_id']}-{r['hi_mcd_id']}": r["polyline"] for r in csv.DictReader(f)}
    n = len(mcd_ids)
    assert len(legs) == n * (n - 1) // 2, "route_legs.csv doesn't cover every location pair"
    LEGS_OUT.parent.mkdir(exist_ok=True)
    LEGS_OUT.write_text(json.dumps(legs, separators=(",", ":"), sort_keys=True) + "\n")
    return len(legs)


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
    coords = {int(r["id"]): (float(r["lat"]), float(r["lon"])) for r in rows}

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
            f"City {elm_string(nicknames[mcd_id])} {elm_string(addresses[mcd_id])} {coords[mcd_id][0]} {coords[mcd_id][1]} {windows_elm(open_windows)} {windows_elm(closed_windows)}"
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


{{-| `address` is the street line only (e.g. "160 Broadway"). `lat`/`lon`
are WGS 84 degrees.
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
    , lat : Float
    , lon : Float
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


def path_xs(d):
    """Every point's absolute x in a path of `M`/`L` (absolute) and `l`
    (relative) line moves, as ST_AsSVG writes them."""
    xs = []
    x = 0.0
    relative = False
    tokens = d.split()
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t in ("M", "L", "l"):
            relative = t == "l"
            i += 1
            continue
        x = x + float(t) if relative else float(t)
        xs.append(x)
        i += 2
    return xs


def route_view_box(view_box, locations, edges):
    """`view_box` narrowed horizontally to just the locations and route paths
    (full height kept), for the simulator's "stretch" map."""
    xs = [cx for _, cx, _ in locations]
    for d in edges:
        xs.extend(path_xs(d))
    _, min_y, _, height = view_box.split()
    return f"{min(xs)} {min_y} {round(max(xs) - min(xs), 1)} {height}"


def write_elm(view_box, borough_d, locations, edges, legs):
    ids_list = ", ".join(str(mcd_id) for mcd_id, _, _ in locations)
    coords_list = ", ".join(f"( {cx}, {cy} )" for _, cx, cy in locations)
    legs_list = "\n        , ".join(
        f"( ( {lo}, {hi} ), {elm_string(d)} )" for (lo, hi), d in sorted(legs.items())
    )

    elm_source = f"""module MctrotMapData exposing (boroughPath, legPaths, locationCoords, mapViewBox, mcdIds, routeNetworkPath, routeViewBox)

{{-| Generated by website/data/generate_elm_data.py from website/data/mctrot_map.svg.
Do not hand-edit; re-run the script instead.
-}}

import Array exposing (Array)
import Dict exposing (Dict)


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


{{-| Every real-street road segment any route uses, as one path of
disconnected `M ... L ...` subpaths.
-}}
routeNetworkPath : String
routeNetworkPath =
    {elm_string(" ".join(edges))}


{{-| One continuous path per location pair, keyed by `( lo, hi )` `mcdIds`
values with `lo < hi`, walking that pair's shortest route from `lo` to `hi`
(relative moves, so each begins with an absolute `M`).
-}}
legPaths : Dict ( Int, Int ) String
legPaths =
    Dict.fromList
        [ {legs_list}
        ]
"""
    ELM_OUT.write_text(elm_source)


def write_css():
    lines = [
        # The map is stretched non-uniformly to fill its box, so every stroke
        # is non-scaling and sized in screen pixels. Locations are zero-length
        # round-capped paths, which stay circular under the stretch.
        # Route legs are single strokes, round-joined so corners stay clean;
        # --route-active recolors them. Location markers are
        # HTML over the map (see viewLocationLayer in src/Simulator.elm), so
        # they keep their shape too.
        ".borough { fill: #000; stroke: #999; stroke-width: 0.5px; vector-effect: non-scaling-stroke; }",
        ".route-edge { fill: none; stroke: #ccc; stroke-width: 1px; vector-effect: non-scaling-stroke; }",
        ".route-leg { fill: none; stroke: var(--route-active, #FFD100); stroke-width: 8px; stroke-linejoin: round; stroke-linecap: round; vector-effect: non-scaling-stroke; }",
        ".location { position: absolute; transform: translate(-50%, -50%); }",
        ".location-stop { width: 5px; height: 5px; border-radius: 50%; background: #FF0000; }",
        ".location-start, .location-finish { width: 14px; height: 14px; border: 1px solid #fff; transform: translate(-50%, -50%) rotate(45deg); }",
        ".location-start { background: #1a9e3a; }",
        ".location-finish { background: conic-gradient(#000 0 25%, #fff 0 50%, #000 0 75%, #fff 0); }",
    ]
    CSS_OUT.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
