set -euo pipefail

psql -h 127.0.0.1 -d mctrot --command "drop table if exists borough cascade;"
psql -h 127.0.0.1 -d mctrot --command "drop table if exists mcd cascade;"
psql -h 127.0.0.1 -d mctrot --command "drop table if exists sidewalk cascade;"
psql -h 127.0.0.1 -d mctrot --command "drop table if exists sidewalk_centerline cascade;"
psql -h 127.0.0.1 -d mctrot --command "drop table if exists street_centerline cascade;"
psql -h 127.0.0.1 -d mctrot --command "drop table if exists hudson cascade;"
