# sidewalk
ogr2ogr -f "PostgreSQL" \
  PG:"dbname=mctrot host=127.0.0.1 port=5432" \
  "data/NYC Planimetric Database_ Sidewalk_20240806.geojson" \
  -nln sidewalk \
  -t_srs "EPSG:4326" \
  -lco GEOM_TYPE=geography \
  -lco OVERWRITE=YES;

psql -h 127.0.0.1 -d mctrot << SQL
  CREATE OR REPLACE VIEW mcisland_sidewalk AS
  SELECT sidewalk.* FROM sidewalk
  INNER JOIN mcisland ON ST_CONTAINS(mcisland.the_geog::geometry, sidewalk.the_geog::geometry);
SQL
