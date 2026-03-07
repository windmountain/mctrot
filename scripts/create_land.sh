set -euo pipefail

psql -h 127.0.0.1 -p 5432 -d mctrot << 'SQL'

DROP TABLE IF EXISTS land;

CREATE TABLE land AS
SELECT ST_Union(
  ARRAY(
    SELECT the_geog::geometry FROM ny_counties
    UNION ALL
    SELECT the_geog::geometry FROM nj_counties
  )
)::geography AS the_geog;

CREATE INDEX land_the_geog_idx ON land USING gist(the_geog);

SQL
