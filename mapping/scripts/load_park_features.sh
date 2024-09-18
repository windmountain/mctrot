set -euo pipefail

# sidewalk_centerline
ogr2ogr -f "PostgreSQL" \
  PG:"dbname=mctrot host=127.0.0.1 port=5432" \
  "data/NYC Planimetric Database_ Open Space (Parks)_20240814.geojson" \
  -nln park_feature \
  -t_srs "EPSG:4326" \
  -lco GEOM_TYPE=geography \
  -lco OVERWRITE=YES;

psql -h 127.0.0.1 -d mctrot << SQL
  CREATE OR REPLACE VIEW mcisland_park_feature AS
  SELECT park_feature.*
  FROM park_feature
  JOIN mcisland ON ST_CONTAINS(mcisland.the_geog::geometry, park_feature.the_geog::geometry)
SQL
