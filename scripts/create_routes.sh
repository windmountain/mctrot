set -euo pipefail

# Create routes between every pair of McDonald's locations along sidewalk centerlines
# using pgRouting's many-to-many Dijkstra algorithm.

# TODO: Also implement per-pair pgr_dijkstra approach as a comparative benchmark.

psql -h 127.0.0.1 -p 5432 -d mctrot << 'SQL'

-- Step 1: Build a routable network from sidewalk centerlines.
-- pgRouting needs geometry (not geography) and single linestrings (not multi).

DROP TABLE IF EXISTS sidewalk_routing_vertices_pgr CASCADE;
DROP TABLE IF EXISTS sidewalk_routing CASCADE;

CREATE TABLE sidewalk_routing AS
SELECT
  ogc_fid AS id,
  st_label,
  full_stree,
  st_width,
  (ST_Dump(the_geog::geometry)).geom AS the_geom
FROM mcisland_sidewalk_centerline;

ALTER TABLE sidewalk_routing ADD COLUMN source INTEGER;
ALTER TABLE sidewalk_routing ADD COLUMN target INTEGER;

-- Cost is the length in meters
ALTER TABLE sidewalk_routing ADD COLUMN cost DOUBLE PRECISION;
UPDATE sidewalk_routing SET cost = ST_Length(the_geom::geography);

CREATE INDEX sidewalk_routing_geom_idx ON sidewalk_routing USING gist(the_geom);

-- Build topology with a 1-meter tolerance for snapping endpoints
SELECT pgr_createTopology(
  'sidewalk_routing',
  0.00001,  -- ~1 meter tolerance in degrees
  'the_geom',
  'id'
);

-- Step 2: Snap each McDonald's location to the nearest network vertex.

DROP TABLE IF EXISTS mcd_routing_node CASCADE;

CREATE TABLE mcd_routing_node AS
SELECT
  m.ogc_fid AS mcd_id,
  m.addressline1,
  m.shortdescription,
  v.id AS vertex_id,
  ST_Distance(m.the_geog, v.the_geom::geography) AS snap_distance_meters
FROM mcisland_mcd m
CROSS JOIN LATERAL (
  SELECT id, the_geom
  FROM sidewalk_routing_vertices_pgr
  ORDER BY the_geom <-> m.the_geog::geometry
  LIMIT 1
) v;

-- Step 3: Compute all-pairs shortest paths using many-to-many Dijkstra.

DROP TABLE IF EXISTS route_dijkstra CASCADE;

CREATE TABLE route_dijkstra AS
SELECT *
FROM pgr_dijkstra(
  'SELECT id, source, target, cost, cost AS reverse_cost FROM sidewalk_routing',
  (SELECT array_agg(DISTINCT vertex_id) FROM mcd_routing_node),
  (SELECT array_agg(DISTINCT vertex_id) FROM mcd_routing_node),
  directed := false
);

-- Step 4a: Route geometries — one merged line per pair of McDonald's locations.

DROP TABLE IF EXISTS route CASCADE;

CREATE TABLE route AS
SELECT
  src.mcd_id AS from_mcd_id,
  src.addressline1 AS from_address,
  dst.mcd_id AS to_mcd_id,
  dst.addressline1 AS to_address,
  rd.start_vid,
  rd.end_vid,
  ST_LineMerge(ST_Union(sr.the_geom))::geography AS the_geog
FROM route_dijkstra rd
JOIN sidewalk_routing sr ON rd.edge = sr.id
JOIN mcd_routing_node src ON rd.start_vid = src.vertex_id
JOIN mcd_routing_node dst ON rd.end_vid = dst.vertex_id
WHERE rd.edge != -1
GROUP BY src.mcd_id, src.addressline1, dst.mcd_id, dst.addressline1,
         rd.start_vid, rd.end_vid;

CREATE INDEX route_geog_idx ON route USING gist(the_geog);

-- Step 4b: Route summary — distance between each pair.

DROP TABLE IF EXISTS route_summary CASCADE;

CREATE TABLE route_summary AS
SELECT
  from_mcd_id,
  from_address,
  to_mcd_id,
  to_address,
  ST_Length(the_geog) AS distance_meters
FROM route
ORDER BY from_mcd_id, to_mcd_id;

-- Step 5: View of sidewalk segments that appear in any route, for QGIS labeling.

CREATE OR REPLACE VIEW route_segment AS
SELECT DISTINCT sr.id, sr.st_label, sr.full_stree, sr.the_geom::geography AS the_geog
FROM route_dijkstra rd
JOIN sidewalk_routing sr ON rd.edge = sr.id
WHERE rd.edge != -1;

SQL
