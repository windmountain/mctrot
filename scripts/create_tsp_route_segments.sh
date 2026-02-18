set -euo pipefail

psql -h 127.0.0.1 -p 5432 -d mctrot << 'SQL'

DROP TABLE IF EXISTS tsp_route_segments;

CREATE TABLE tsp_route_segments AS
SELECT
  a.stop_order,
  a.mcd_id        AS from_mcd_id,
  a.addressline1  AS from_address,
  b.mcd_id        AS to_mcd_id,
  b.addressline1  AS to_address,
  sr.st_label,
  sr.full_stree,
  sr.the_geom::geography AS the_geog
FROM tsp_route a
JOIN tsp_route b
  ON b.stop_order = (a.stop_order % (SELECT MAX(stop_order) FROM tsp_route)) + 1
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

CREATE INDEX tsp_route_segments_geog_idx ON tsp_route_segments USING gist(the_geog);

SQL
