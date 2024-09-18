set -euo pipefail

. $(dirname "$0")/create_extensions.sh
. $(dirname "$0")/load_boroughs.sh
. $(dirname "$0")/load_mcds.sh
. $(dirname "$0")/load_mcghosts.sh
. $(dirname "$0")/create_mcislands.sh
. $(dirname "$0")/load_sidewalk_centerlines.sh
. $(dirname "$0")/load_sidewalks.sh
. $(dirname "$0")/load_street_centerlines.sh
. $(dirname "$0")/load_park_features.sh
. $(dirname "$0")/load_hudson.sh
