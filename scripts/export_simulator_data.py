"""Export the website simulator's input data from the database into
website/data/, then run website/data/generate_elm_data.py to turn it into Elm.

Writes:
  - mcd_locations.csv: one row per Manhattan location (mcisland_mcd), with its
    nickname (or its street address if it has none yet; run the
    nickname-interview devenv script to name it) and the raw per-day hours
    for reference.
  - mcd_hours.csv: the parsed hours from the mcd_hours view (one row per
    location per weekday, 0 = Monday), which the simulator actually uses.
  - route_summary.csv: walking distance for each ordered location pair.
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
        string_agg(h.hours, '|' ORDER BY h.weekday)
    FROM mcisland_mcd m
    LEFT JOIN nicknames n ON n.nationalstorenumber = m.nationalstorenumber
    JOIN mcd_hours h ON h.mcd_id = m.ogc_fid
    GROUP BY m.ogc_fid, n.nickname, m.shortdescription, m.longdescription, m.addressline1, m.customaddress
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

conn.close()

OUT.mkdir(parents=True, exist_ok=True)

with open(OUT / "mcd_locations.csv", "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["id", "nickname", "shortdescription", "longdescription", "address", "hours"])
    for mcd_id, nickname, short, long, address, day_hours in locations:
        hours_text = "; ".join(f"{d} {h}" for d, h in zip(DAY_ABBR, day_hours.split("|")))
        w.writerow([mcd_id, nickname, short, long, address, hours_text])

with open(OUT / "mcd_hours.csv", "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["mcd_id", "weekday", "open_minute", "close_minute"])
    w.writerows(hours)

with open(OUT / "route_summary.csv", "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["from_mcd_id", "to_mcd_id", "distance_meters"])
    w.writerows(routes)

shutil.copyfile(MAP_SVG, OUT / "mctrot_map.svg")

print(f"wrote {len(locations)} locations, {len(hours)} hours rows, {len(routes)} routes to {OUT}")

subprocess.run([sys.executable, str(OUT / "generate_elm_data.py")], check=True)
