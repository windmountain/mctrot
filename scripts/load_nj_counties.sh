set -euo pipefail

ogr2ogr -f "PostgreSQL" \
  PG:"dbname=mctrot host=127.0.0.1 port=5432" \
  "data/nj-county-boundaries.geojson" \
  -nln nj_counties \
  -t_srs "EPSG:4326" \
  -lco GEOM_TYPE=geography \
  -lco OVERWRITE=YES;
