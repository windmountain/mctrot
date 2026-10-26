# pednetwork
ogr2ogr -f "PostgreSQL" \
  PG:"dbname=mctrot host=127.0.0.1 port=5432" \
  "/vsizip/data/pedestrian-network-flows.zip/NYC_pednetwork_estimates_counts_2018-2019.geojson" \
  -nln pednetwork \
  -s_srs "EPSG:6538" \
  -t_srs "EPSG:4326" \
  -lco GEOM_TYPE=geography \
  -lco OVERWRITE=YES;

psql -h 127.0.0.1 -p 5432 -d mctrot << 'SQL'
  CREATE OR REPLACE VIEW mcisland_pednetwork AS
  SELECT pednetwork.* FROM pednetwork
  INNER JOIN mcisland ON ST_CONTAINS(mcisland.the_geog::geometry, pednetwork.the_geog::geometry);
SQL
