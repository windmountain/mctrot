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
  COALESCE(r1.the_geog, r2.the_geog) AS the_geog
FROM tsp_route a
JOIN tsp_route b
  ON b.stop_order = (a.stop_order % (SELECT MAX(stop_order) FROM tsp_route)) + 1
LEFT JOIN route r1 ON r1.from_mcd_id = a.mcd_id AND r1.to_mcd_id = b.mcd_id
LEFT JOIN route r2 ON r2.from_mcd_id = b.mcd_id AND r2.to_mcd_id = a.mcd_id;

CREATE INDEX tsp_route_segments_geog_idx ON tsp_route_segments USING gist(the_geog);

SQL
