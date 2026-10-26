set -euo pipefail

# Per-pair-tagged, deduplicated sidewalk edges for the SVG map export.
#
# Unlike route_segment (which only dissolves route_dijkstra edges to
# distinct geometry for QGIS labeling), this preserves which location-pair(s)
# traverse each edge, so the exported SVG can tag each edge with a CSS class
# per pair and a frontend can toggle one pair's route without duplicating
# geometry.

psql -h 127.0.0.1 -p 5432 -d mctrot << 'SQL'

DROP TABLE IF EXISTS route_pair_edge CASCADE;

CREATE TABLE route_pair_edge AS
SELECT DISTINCT
  rd.edge AS sidewalk_routing_id,
  LEAST(src.mcd_id, dst.mcd_id)    AS mcd_lo,
  GREATEST(src.mcd_id, dst.mcd_id) AS mcd_hi
FROM route_dijkstra rd
JOIN mcd_routing_node src ON rd.start_vid = src.vertex_id
JOIN mcd_routing_node dst ON rd.end_vid   = dst.vertex_id
WHERE rd.edge != -1;

CREATE INDEX route_pair_edge_edge_idx ON route_pair_edge (sidewalk_routing_id);
CREATE INDEX route_pair_edge_pair_idx ON route_pair_edge (mcd_lo, mcd_hi);

-- One row per distinct sidewalk edge used by any route, with every
-- location-pair that traverses it collapsed into a CSS class list
-- (e.g. '{l1-l102,l70-l71}').

CREATE OR REPLACE VIEW route_segment_pairs AS
SELECT
  sr.id,
  sr.st_label,
  sr.full_stree,
  sr.the_geom,
  array_agg(DISTINCT 'l' || rpe.mcd_lo || '-l' || rpe.mcd_hi) AS pair_classes,
  count(DISTINCT (rpe.mcd_lo, rpe.mcd_hi)) AS pair_count
FROM route_pair_edge rpe
JOIN sidewalk_routing sr ON sr.id = rpe.sidewalk_routing_id
GROUP BY sr.id, sr.st_label, sr.full_stree, sr.the_geom;

SQL
