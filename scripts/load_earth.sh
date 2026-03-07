set -euo pipefail

psql -h 127.0.0.1 -p 5432 -d mctrot << 'SQL'

DROP TABLE IF EXISTS earth;

CREATE TABLE earth (
  the_geom geometry(Polygon, 4326)
);

INSERT INTO earth (the_geom)
VALUES (ST_GeomFromGeoJSON('{
  "type": "Polygon",
  "coordinates": [[
    [-180, -90],
    [ 180, -90],
    [ 180,  90],
    [-180,  90],
    [-180, -90]
  ]]
}'));

SQL
