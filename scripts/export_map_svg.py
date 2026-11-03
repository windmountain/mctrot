import psycopg

# ROTATION_DEGREES is the street grid angle — the circular mean azimuth
# (mod 180) of 5th Ave's Manhattan segments in EPSG:2263 — not the island
# coastline's long axis (that's 23.1°; the two differ because the coastline
# doesn't perfectly track the grid). Recompute if street_centerline data
# is reloaded:
#
#   WITH seg AS (
#     SELECT ST_LineMerge(ST_Transform(the_geog::geometry, 2263)) AS g
#     FROM street_centerline
#     WHERE full_street_name = '5 AVE' AND boroughcode = '1'
#   ),
#   az AS (
#     SELECT mod(degrees(ST_Azimuth(ST_StartPoint(g), ST_EndPoint(g)))::numeric, 180) AS az,
#            ST_Length(g) AS len
#     FROM seg WHERE GeometryType(g) = 'LINESTRING'
#   )
#   SELECT degrees(atan2(sum(sin(radians(az::float)*2)), sum(cos(radians(az::float)*2))))/2
#   FROM az WHERE len > 50 AND az IS NOT NULL;
ROTATION_DEGREES = 29.0

VIEWBOX_PADDING_FEET = 1000

conn = psycopg.connect("dbname=mctrot host=127.0.0.1 port=5432")

center_wkt = conn.execute(
    "SELECT ST_AsText(ST_Centroid(ST_Transform(the_geog::geometry, 2263))) FROM mcisland"
).fetchone()[0]
params = {"center": center_wkt, "rotation": ROTATION_DEGREES}

borough_svg, xmin, xmax, ymin, ymax = conn.execute(
    """
    WITH b AS (
      SELECT ST_Rotate(
        ST_Transform(the_geog::geometry, 2263),
        radians(%(rotation)s),
        ST_GeomFromText(%(center)s, 2263)
      ) AS g
      FROM mcisland
    )
    SELECT ST_AsSVG(g, 0, 1), ST_XMin(g), ST_XMax(g), ST_YMin(g), ST_YMax(g) FROM b
    """,
    params,
).fetchone()

location_rows = conn.execute(
    """
    WITH l AS (
      SELECT ogc_fid, ST_Rotate(
        ST_Transform(the_geog::geometry, 2263),
        radians(%(rotation)s),
        ST_GeomFromText(%(center)s, 2263)
      ) AS g
      FROM mcisland_mcd
    )
    SELECT ogc_fid, ST_AsSVG(g, 0, 1) FROM l ORDER BY ogc_fid
    """,
    params,
).fetchall()

edge_rows = conn.execute(
    """
    WITH e AS (
      SELECT id, ST_Rotate(
        ST_Transform(the_geom, 2263),
        radians(%(rotation)s),
        ST_GeomFromText(%(center)s, 2263)
      ) AS g
      FROM route_segment_pairs
    )
    SELECT id, ST_AsSVG(g, 1, 0) FROM e ORDER BY id
    """,
    params,
).fetchall()

# One continuous path per unordered location pair, walking from the lower
# mcd_id to the higher, so a highlighted route is drawn as a single stroke
# with real joins at every corner. Each route_dijkstra step's `node` is the
# vertex it leaves from, always one end of its edge, so an edge drawn the
# other way is reversed to keep the points in walking order (the same
# stitching as export_simulator_data.py's route_legs.csv). Simplified to
# within 3 ft and written as relative whole-foot moves to keep the
# simulator's script small.
leg_rows = conn.execute(
    """
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
    SELECT lo, hi, ST_AsSVG(
      ST_Simplify(
        ST_Rotate(ST_Transform(g, 2263), radians(%(rotation)s), ST_GeomFromText(%(center)s, 2263)),
        3
      ),
      1, 0
    )
    FROM legs
    ORDER BY lo, hi
    """,
    params,
).fetchall()

conn.close()

view_x = xmin - VIEWBOX_PADDING_FEET
view_y = -ymax - VIEWBOX_PADDING_FEET
view_w = (xmax - xmin) + 2 * VIEWBOX_PADDING_FEET
view_h = (ymax - ymin) + 2 * VIEWBOX_PADDING_FEET

location_elements = "\n".join(
    f'      <circle id="mcd-{ogc_fid}" class="location" data-mcd-id="{ogc_fid}" {svg} r="150"/>'
    for ogc_fid, svg in location_rows
)

edge_elements = "\n".join(
    f'      <path id="edge-{edge_id}" class="route-edge" d="{svg}"/>'
    for edge_id, svg in edge_rows
)

leg_elements = "\n".join(
    f'      <path id="leg-{lo}-{hi}" class="route-leg" data-lo="{lo}" data-hi="{hi}" d="{svg}"/>'
    for lo, hi, svg in leg_rows
)

svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view_x:.1f} {view_y:.1f} {view_w:.1f} {view_h:.1f}">
  <style>
    .borough {{ fill: #000; stroke: #999; stroke-width: 20; }}
    .route-edge {{ fill: none; stroke: #ccc; stroke-width: 55; }}
    .route-leg {{ display: none; fill: none; stroke: #FFD100; stroke-width: 55; stroke-linejoin: round; stroke-linecap: round; }}
    .location {{ fill: #FFD100; stroke: #fff; stroke-width: 4; }}
  </style>
  <g id="layer-borough">
    <path class="borough" d="{borough_svg}"/>
  </g>
  <g id="layer-routes">
{edge_elements}
  </g>
  <g id="layer-legs">
{leg_elements}
  </g>
  <g id="layer-locations">
{location_elements}
  </g>
</svg>
"""

with open("output/mctrot_map.svg", "w") as f:
    f.write(svg)

print("Saved output/mctrot_map.svg")
