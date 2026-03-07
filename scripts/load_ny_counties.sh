set -euo pipefail

unzip -o "data/nys-civil-boundaries.zip" "Shapefiles/Counties_Shoreline.*" -d "data/"

ogr2ogr -f "PostgreSQL" \
  PG:"dbname=mctrot host=127.0.0.1 port=5432" \
  "data/Shapefiles/Counties_Shoreline.shp" \
  -nln ny_counties \
  -nlt MULTIPOLYGON \
  -t_srs "EPSG:4326" \
  -fieldTypeToString Date \
  -sql "SELECT NAME, ABBREV, GNIS_ID, FIPS_CODE, SWIS, NYSP_ZONE, POP1990, POP2000, POP2010, POP2020, DOS_LL, NYC FROM Counties_Shoreline" \
  -lco GEOM_TYPE=geography \
  -lco OVERWRITE=YES
