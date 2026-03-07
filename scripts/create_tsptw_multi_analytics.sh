set -euo pipefail

psql -h 127.0.0.1 -p 5432 -d mctrot << 'SQL'

DROP TABLE IF EXISTS tsptw_multi_analytics;

CREATE TABLE tsptw_multi_analytics AS
SELECT
  ROUND(s.pace_min_per_mi::numeric, 1) AS pace_min_per_mi,
  ROUND(SUM(ST_Length(s.the_geog))::numeric, 2) AS length_m,
  CASE WHEN ROUND(SUM(ST_Length(s.the_geog))::numeric, 2) = MIN(ROUND(SUM(ST_Length(s.the_geog))::numeric, 2)) OVER () THEN '*' ELSE '' END AS m,
  ROUND((SELECT SUM(travel_min + wait_min + service_min) FROM tsptw_multi_route WHERE pace_min_per_mi = s.pace_min_per_mi) / 60::numeric, 1) AS total_hr,
  CASE WHEN ROUND((SELECT SUM(travel_min + wait_min + service_min) FROM tsptw_multi_route WHERE pace_min_per_mi = s.pace_min_per_mi) / 60::numeric, 1) = MIN(ROUND((SELECT SUM(travel_min + wait_min + service_min) FROM tsptw_multi_route WHERE pace_min_per_mi = s.pace_min_per_mi) / 60::numeric, 1)) OVER () THEN '*' ELSE '' END AS t,
  ROUND((MIN(r.minutes_to_close) / 60)::numeric, 1) AS hours_to_close_min,
  (SELECT arrival FROM tsptw_multi_route
   WHERE pace_min_per_mi = s.pace_min_per_mi
   ORDER BY stop_order DESC LIMIT 1)               AS end_arrival
FROM tsptw_multi_route_segments s
JOIN tsptw_multi_route r
  ON  r.pace_min_per_mi = s.pace_min_per_mi
  AND r.mcd_id          = s.from_mcd_id
GROUP BY s.pace_min_per_mi
ORDER BY s.pace_min_per_mi;

SQL

psql -h 127.0.0.1 -p 5432 -d mctrot << 'SQL'
SELECT
  pace_min_per_mi,
  length_m,
  m,
  total_hr,
  t,
  hours_to_close_min,
  end_arrival
FROM tsptw_multi_analytics
ORDER BY pace_min_per_mi;
SQL
