set -euo pipefail

ogr2ogr -f "PostgreSQL" \
  PG:"dbname=mctrot host=127.0.0.1 port=5432" \
  "data/manhattanMcDs.geojson" \
  -nln mcd \
  -t_srs "EPSG:4326" \
  -lco GEOM_TYPE=geography \
  -lco OVERWRITE=YES;

psql -h 127.0.0.1 -d mctrot << SQL
  CREATE OR REPLACE VIEW mcisland_mcd AS
  SELECT mcd.* FROM mcd
  JOIN borough ON ST_CONTAINS(borough.the_geog::geometry, mcd.the_geog::geometry)
  AND borough.boro_name = 'Manhattan'
SQL
    
