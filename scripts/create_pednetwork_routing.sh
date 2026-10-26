set -euo pipefail

# Build a routable network from the pednetwork data, alongside (not replacing)
# the existing sidewalk_routing network. Working assumption: wider sidewalks
# exist because they carry more foot traffic, so raw predicted volume is used
# as the crowding signal directly, without a separate width/density term.

psql -h 127.0.0.1 -p 5432 -d mctrot << 'SQL'

DROP TABLE IF EXISTS pednetwork_routing_vertices_pgr CASCADE;
DROP TABLE IF EXISTS pednetwork_routing CASCADE;

CREATE TABLE pednetwork_routing AS
SELECT
  ogc_fid AS id,
  predwkdyam AS pred_weekday_am,
  predwkdymd AS pred_weekday_midday,
  predwkdypm AS pred_weekday_pm,
  predwkndam AS pred_weekend_am,
  predwkndmd AS pred_weekend_midday,
  predwkndpm AS pred_weekend_pm,
  (ST_Dump(the_geog::geometry)).geom AS the_geom
FROM mcisland_pednetwork;

ALTER TABLE pednetwork_routing ADD COLUMN source INTEGER;
ALTER TABLE pednetwork_routing ADD COLUMN target INTEGER;

ALTER TABLE pednetwork_routing ADD COLUMN cost DOUBLE PRECISION;
UPDATE pednetwork_routing SET cost = ST_Length(the_geom::geography);

CREATE INDEX pednetwork_routing_geom_idx ON pednetwork_routing USING gist(the_geom);

SELECT pgr_createTopology(
  'pednetwork_routing',
  0.00001,  -- ~1 meter tolerance in degrees
  'the_geom',
  'id'
);

-- Snap each McDonald's location to the pednetwork graph. Named distinctly
-- from mcd_routing_node (the existing sidewalk_routing-based snap table),
-- which is left untouched.

DROP TABLE IF EXISTS mcd_routing_node_pednetwork CASCADE;

CREATE TABLE mcd_routing_node_pednetwork AS
SELECT
  m.ogc_fid AS mcd_id,
  m.addressline1,
  m.shortdescription,
  v.id AS vertex_id,
  ST_Distance(m.the_geog, v.the_geom::geography) AS snap_distance_meters
FROM mcisland_mcd m
CROSS JOIN LATERAL (
  SELECT id, the_geom
  FROM pednetwork_routing_vertices_pgr
  ORDER BY the_geom <-> m.the_geog::geometry
  LIMIT 1
) v;

SQL
