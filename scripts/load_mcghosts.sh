set -euo pipefail

ogr2ogr -f "PostgreSQL" \
  PG:"dbname=mctrot host=127.0.0.1 port=5432" \
  "data/mcghosts_geocoded.csv" \
  -oo X_POSSIBLE_NAMES=lon \
  -oo Y_POSSIBLE_NAMES=lat \
  -s_srs "EPSG:4326" \
  -nln raw_phonebook_listing \
  -t_srs "EPSG:4326" \
  -lco GEOM_TYPE=geography \
  -lco OVERWRITE=YES;

psql -h 127.0.0.1 -d mctrot << SQL
  CREATE OR REPLACE VIEW
      phonebook_listing AS
  SELECT
      raw_phonebook_listing.*,
      CAST(SPLIT_PART(year, '-', 1) AS int) AS min_year,
      CAST(
          COALESCE(NULLIF(SPLIT_PART(year, '-', 2), ''), year) AS int
      ) AS max_year
  FROM
      raw_phonebook_listing
      JOIN borough ON ST_CONTAINS (
          borough.the_geog::geometry,
          raw_phonebook_listing.the_geog::geometry
      )
      AND borough.boro_name = 'Manhattan';
SQL

psql -h 127.0.0.1 -d mctrot << SQL
  CREATE OR REPLACE VIEW
      mcghost AS
  SELECT DISTINCT
      (l.address),
      min(l.min_year) OVER by_address AS first_seen,
      max(l.max_year) OVER by_address AS last_seen,
      l.the_geog,
      mcd.id
  FROM
      phonebook_listing l
  LEFT JOIN mcisland_mcd mcd ON ST_DISTANCE(mcd.the_geog::geometry, l.the_geog::geometry) < 0.0015
  WHERE mcd.id IS NULL
  WINDOW
      by_address AS (
          PARTITION BY
              address
      )
  ORDER BY
      first_seen,
      address;
SQL

