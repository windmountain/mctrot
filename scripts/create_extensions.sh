set -euo pipefail


psql -h 127.0.0.1 -d mctrot << SQL
  CREATE EXTENSION IF NOT EXISTS postgis;
SQL
