# set -euo pipefail

{
psql -h 127.0.0.1 -p 5432 << SQL
  CREATE DATABASE mctrot;
SQL
} && echo "No worries if it already existed"
