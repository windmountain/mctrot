set -euo pipefail

psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists borough cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists mcd cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists sidewalk cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists sidewalk_centerline cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists street_centerline cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists raw_phonebook_listing cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists park_feature cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists hudson cascade;"

. $(dirname "$0")/drop_extensions.sh
