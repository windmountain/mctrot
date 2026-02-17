set -euo pipefail

psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists borough cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists mcd cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists sidewalk cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists sidewalk_centerline cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists street_centerline cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists raw_phonebook_listing cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists park_feature cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists hudson cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists route cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists route_summary cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists route_dijkstra cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists mcd_routing_node cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists sidewalk_routing cascade;"
psql -h 127.0.0.1 -p 5432 -d mctrot --command "drop table if exists sidewalk_routing_vertices_pgr cascade;"

. $(dirname "$0")/drop_extensions.sh
