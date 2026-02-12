# street_centerline

ogr2ogr -f "PostgreSQL" \
  PG:"dbname=mctrot host=127.0.0.1 port=5432" \
  "data/NYC Street Centerline (CSCL).geojson" \
  -nln street_centerline \
  -t_srs "EPSG:4326" \
  -lco GEOM_TYPE=geography \
  -lco OVERWRITE=YES \
  -lco COLUMN_TYPES="st_width:NUMERIC";

psql -h 127.0.0.1 -d mctrot << SQL
  CREATE OR REPLACE VIEW mcisland_street_centerline AS
  SELECT street_centerline.*,
  (street_centerline.st_width * 0.3048) AS st_width_meters
  FROM street_centerline
  JOIN mcisland ON ST_CONTAINS(mcisland.the_geog::geometry, street_centerline.the_geog::geometry)
SQL
    
