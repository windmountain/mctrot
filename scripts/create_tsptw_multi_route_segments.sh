set -euo pipefail

psql -h 127.0.0.1 -p 5432 -d mctrot << 'SQL'

DROP TABLE IF EXISTS tsptw_multi_route_segments;

CREATE TABLE tsptw_multi_route_segments AS
SELECT
  a.pace_min_per_mi,
  a.stop_order,
  a.mcd_id        AS from_mcd_id,
  a.addressline1  AS from_address,
  b.mcd_id        AS to_mcd_id,
  b.addressline1  AS to_address,
  sr.st_label,
  sr.full_stree,
  sr.the_geom::geography AS the_geog
FROM tsptw_multi_route a
JOIN tsptw_multi_route b
  ON  b.pace_min_per_mi = a.pace_min_per_mi
  AND b.stop_order      = a.stop_order + 1
JOIN mcd_routing_node src ON src.mcd_id = a.mcd_id
JOIN mcd_routing_node dst ON dst.mcd_id = b.mcd_id
JOIN route_dijkstra rd
  ON  rd.edge != -1
  AND (
    (rd.start_vid = src.vertex_id AND rd.end_vid = dst.vertex_id)
    OR
    (rd.start_vid = dst.vertex_id AND rd.end_vid = src.vertex_id)
  )
JOIN sidewalk_routing sr ON sr.id = rd.edge;

CREATE INDEX tsptw_multi_route_segments_geog_idx  ON tsptw_multi_route_segments USING gist(the_geog);
CREATE INDEX tsptw_multi_route_segments_pace_idx   ON tsptw_multi_route_segments (pace_min_per_mi);

SQL
