set -euo pipefail

ogr2ogr -f "PostgreSQL" \
  PG:"dbname=mctrot host=127.0.0.1 port=5432" \
  "data/mcghosts_geocoded.csv" \
  -oo X_POSSIBLE_NAMES=lon \
  -oo Y_POSSIBLE_NAMES=lat \
  -s_srs "EPSG:4326" \
  -nln mcghost \
  -t_srs "EPSG:4326" \
  -lco GEOM_TYPE=geography \
  -lco OVERWRITE=YES;

# psql -h 127.0.0.1 -d mctrot << SQL
# 
#   CREATE TABLE phonebook_listing_raw (id SERIAL PRIMARY KEY, year text, phonebook text, name text, address text, phone varchar(18), latitude float, longitude float);
# 
#   COPY phonebook_listing_raw(year, phonebook, name, address, phone, latitude, longitude) FROM '/Users/zachrose/mctrot/mapping/data/mcghosts_geocoded.csv' WITH DELIMITER ',';
# 
#   # CREATE OR REPLACE VIEW phonebook_listing AS SELECT raw.year, raw.phonebook, raw.address, COUNT (raw.address) AS phone_number_count FROM phonebook_listing_raw as raw GROUP BY year, phonebook, address order by year, address;
# 
#   # count unique addresses by year
#   # SELECT l.year, l.phonebook, COUNT(l.phonebook), REPEAT('#', count(l.phonebook)::int) AS histogram FROM phonebook_listing AS l GROUP BY year, phonebook ORDER BY year, phonebook;
# 
# SQL

# psql -h 127.0.0.1 -d mctrot << SQL
#   CREATE OR REPLACE VIEW mcisland_mcd AS
#   SELECT mcd.* FROM mcd
#   JOIN borough ON ST_CONTAINS(borough.the_geog::geometry, mcd.the_geog::geometry)
#   AND borough.boro_name = 'Manhattan'
# SQL
    
