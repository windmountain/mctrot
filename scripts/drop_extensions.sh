set -euo pipefail


psql -h 127.0.0.1 -d mctrot << SQL
  DROP EXTENSION IF EXISTS postgis CASCADE;
SQL
