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
      SELECT id, pair_classes, ST_Rotate(
        ST_Transform(the_geom, 2263),
        radians(%(rotation)s),
        ST_GeomFromText(%(center)s, 2263)
      ) AS g
      FROM route_segment_pairs
    )
    SELECT id, pair_classes, ST_AsSVG(g, 0, 1) FROM e ORDER BY id
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
    f'      <path id="edge-{edge_id}" class="route-edge {" ".join(pair_classes)}" d="{svg}"/>'
    for edge_id, pair_classes, svg in edge_rows
)

svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view_x:.1f} {view_y:.1f} {view_w:.1f} {view_h:.1f}">
  <style>
    .borough {{ fill: #000; stroke: #999; stroke-width: 20; }}
    .route-edge {{ fill: none; stroke: #ccc; stroke-width: 55; }}
    .location {{ fill: #FFD100; stroke: #fff; stroke-width: 4; }}
  </style>
  <g id="layer-borough">
    <path class="borough" d="{borough_svg}"/>
  </g>
  <g id="layer-routes">
{edge_elements}
  </g>
  <g id="layer-locations">
{location_elements}
  </g>
</svg>
"""

with open("output/mctrot_map.svg", "w") as f:
    f.write(svg)

print("Saved output/mctrot_map.svg")
