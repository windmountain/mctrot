# sidewalk
ogr2ogr -f "PostgreSQL" \
  PG:"dbname=mctrot host=127.0.0.1 port=5432" \
  "data/sidewalk-polygons.geojson" \
  -nln sidewalk \
  -t_srs "EPSG:4326" \
  -lco GEOM_TYPE=geography \
  -lco OVERWRITE=YES;

psql -h 127.0.0.1 -p 5432 -d mctrot << SQL
  CREATE OR REPLACE VIEW mcisland_sidewalk AS
  SELECT sidewalk.* FROM sidewalk
  INNER JOIN mcisland ON ST_CONTAINS(mcisland.the_geog::geometry, sidewalk.the_geog::geometry);
SQL
