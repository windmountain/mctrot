"""Export the website simulator's input data from the database into
website/data/, then run website/data/generate_elm_data.py to turn it into Elm.

Writes:
  - mcd_locations.csv: one row per Manhattan location (mcisland_mcd), with its
    nickname (or its street address if it has none yet; run the
    nickname-interview devenv script to name it), its coordinates, and the
    raw per-day hours for reference.
  - mcd_hours.csv: the parsed hours from the mcd_hours view (one row per
    location per weekday, 0 = Monday), which the simulator actually uses.
  - route_summary.csv: walking distance for each ordered location pair.
  - route_legs.csv: the walking path for each unordered location pair, from
    the lower mcd_id to the higher, as a Google encoded polyline (lat/lon,
    precision 5), simplified to within 6 ft. The simulator's GPX export
    follows these.
  - mctrot_map.svg: a copy of output/mctrot_map.svg (run
    scripts/export_map_svg.py first).

Requires scripts/load.sh to have been run, including create_mcd_hours.sh and
load_nicknames.sh.
"""
import csv
import shutil
import subprocess
import sys
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "website" / "data"
MAP_SVG = ROOT / "output" / "mctrot_map.svg"

DAY_ABBR = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

if not MAP_SVG.exists():
    sys.exit(f"{MAP_SVG} is missing; run scripts/export_map_svg.py first")

conn = psycopg.connect("dbname=mctrot host=127.0.0.1 port=5432")

locations = conn.execute("""
    SELECT
        m.ogc_fid,
        COALESCE(n.nickname, m.addressline1),
        m.shortdescription,
        m.longdescription,
        m.addressline1 || ', ' || m.customaddress,
        ST_Y(m.the_geog::geometry),
        ST_X(m.the_geog::geometry),
        string_agg(h.hours, '|' ORDER BY h.weekday)
    FROM mcisland_mcd m
    LEFT JOIN nicknames n ON n.nationalstorenumber = m.nationalstorenumber
    JOIN mcd_hours h ON h.mcd_id = m.ogc_fid
    GROUP BY m.ogc_fid, n.nickname, m.shortdescription, m.longdescription, m.addressline1, m.customaddress, m.the_geog
    ORDER BY m.ogc_fid
""").fetchall()

missing = conn.execute("""
    SELECT m.ogc_fid, m.addressline1
    FROM mcisland_mcd m
    LEFT JOIN nicknames n ON n.nationalstorenumber = m.nationalstorenumber
    WHERE n.nickname IS NULL
""").fetchall()
for mcd_id, address in missing:
    print(f"no nickname for {address} (mcd {mcd_id}); using its address (run nickname-interview to name it)")

hours = conn.execute("""
    SELECT h.mcd_id, h.weekday, h.open_minute, h.close_minute
    FROM mcd_hours h
    JOIN mcisland_mcd m ON m.ogc_fid = h.mcd_id
    ORDER BY h.mcd_id, h.weekday
""").fetchall()

routes = conn.execute("""
    SELECT from_mcd_id, to_mcd_id, distance_meters
    FROM route_summary
    ORDER BY from_mcd_id, to_mcd_id
""").fetchall()

# Each route_dijkstra step's `node` is the vertex it leaves from, always one
# end of its edge, so an edge drawn the other way is reversed to keep the
# leg's points in walking order.
legs = conn.execute("""
    WITH steps AS (
        SELECT src.mcd_id AS lo, dst.mcd_id AS hi, rd.path_seq,
               CASE WHEN rd.node = sr.source THEN sr.the_geom ELSE ST_Reverse(sr.the_geom) END AS g
        FROM route_dijkstra rd
        JOIN mcd_routing_node src ON rd.start_vid = src.vertex_id
        JOIN mcd_routing_node dst ON rd.end_vid = dst.vertex_id
        JOIN sidewalk_routing sr ON sr.id = rd.edge
        WHERE src.mcd_id < dst.mcd_id AND rd.edge <> -1
    ), points AS (
        SELECT lo, hi, path_seq, (ST_DumpPoints(g)).path[1] AS i, (ST_DumpPoints(g)).geom AS p
        FROM steps
    ), legs AS (
        SELECT lo, hi, ST_RemoveRepeatedPoints(ST_MakeLine(p ORDER BY path_seq, i)) AS g
        FROM points
        GROUP BY lo, hi
    )
    SELECT lo, hi, ST_AsGeoJSON(ST_Transform(ST_Simplify(ST_Transform(g, 2263), 6), 4326), 5)::json -> 'coordinates'
    FROM legs
    ORDER BY lo, hi
""").fetchall()

conn.close()


def encode_polyline(lon_lats):
    """Google's encoded polyline algorithm (precision 5) over (lat, lon)
    pairs; see website/src/Polyline.elm for the decoder."""
    out = []
    prev_lat = prev_lon = 0
    for lon, lat in lon_lats:
        lat_e5, lon_e5 = round(lat * 1e5), round(lon * 1e5)
        for delta in (lat_e5 - prev_lat, lon_e5 - prev_lon):
            v = ~(delta << 1) if delta < 0 else delta << 1
            while v >= 0x20:
                out.append(chr((0x20 | (v & 0x1F)) + 63))
                v >>= 5
            out.append(chr(v + 63))
        prev_lat, prev_lon = lat_e5, lon_e5
    return "".join(out)


OUT.mkdir(parents=True, exist_ok=True)

with open(OUT / "mcd_locations.csv", "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["id", "nickname", "shortdescription", "longdescription", "address", "lat", "lon", "hours"])
    for mcd_id, nickname, short, long, address, lat, lon, day_hours in locations:
        hours_text = "; ".join(f"{d} {h}" for d, h in zip(DAY_ABBR, day_hours.split("|")))
        w.writerow([mcd_id, nickname, short, long, address, f"{lat:.6f}", f"{lon:.6f}", hours_text])

with open(OUT / "mcd_hours.csv", "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["mcd_id", "weekday", "open_minute", "close_minute"])
    w.writerows(hours)

with open(OUT / "route_summary.csv", "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["from_mcd_id", "to_mcd_id", "distance_meters"])
    w.writerows(routes)

with open(OUT / "route_legs.csv", "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["lo_mcd_id", "hi_mcd_id", "polyline"])
    for lo, hi, coords in legs:
        w.writerow([lo, hi, encode_polyline(coords)])

shutil.copyfile(MAP_SVG, OUT / "mctrot_map.svg")

print(f"wrote {len(locations)} locations, {len(hours)} hours rows, {len(routes)} routes, {len(legs)} legs to {OUT}")

subprocess.run([sys.executable, str(OUT / "generate_elm_data.py")], check=True)
