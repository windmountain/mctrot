# sidewalk_centerline
ogr2ogr -f "PostgreSQL" \
  PG:"dbname=mctrot host=127.0.0.1 port=5432" \
  "data/SIDEWALK_LINE_20240812.geojson" \
  -nln sidewalk_centerline \
  -t_srs "EPSG:4326" \
  -lco GEOM_TYPE=geography \
  -lco OVERWRITE=YES \
  -lco COLUMN_TYPES="st_width:NUMERIC";

psql -h 127.0.0.1 -d mctrot << SQL
  CREATE OR REPLACE VIEW mcisland_sidewalk_centerline AS
  SELECT sidewalk_centerline.*,
  LEAST((sidewalk_centerline.st_width * 0.3048), 2) AS st_width_meters
  FROM sidewalk_centerline
  JOIN mcisland ON ST_CONTAINS(mcisland.the_geog::geometry, sidewalk_centerline.the_geog::geometry)
SQL
