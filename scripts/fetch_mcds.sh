set -euo pipefail

# Fetch current McDonald's locations from the McDonald's API (two overlapping
# searches, downtown and uptown) and massage them into
# data/manhattan-mcdonalds-locations.geojson. Run by fetch.py (see the
# "script" on that resource in datapackage.json), or directly.

cd "$(dirname "$0")/.."
mkdir -p data

./scripts/fetch_mcds_downtown.sh > data/mcds-downtown-raw.json
./scripts/fetch_mcds_uptown.sh > data/mcds-uptown-raw.json
node ./scripts/massage_mcds.js data/mcds-uptown-raw.json data/mcds-downtown-raw.json \
  > data/manhattan-mcdonalds-locations.geojson
