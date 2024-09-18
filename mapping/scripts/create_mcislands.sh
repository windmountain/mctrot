set -euo pipefail;

#################
# 
#   Here's the story:
#     The borough of Manhattan is a multipolygon containing polygons for Manhattan Island, Roosevelt Island, Marble Hill, and a few others.
#     We don't want to show features on Roosevelt Island because there are no McDonald's on that island.
#     So we need a view of the polygons that contain at least one McDonald's.
#     We're calling these McIslands, and making a view named 'mcisland'
#     In the case of Manhattan, it turns out that all of the McDonald's are on Manhattan Island, so 'mcisland' will only have one row.
#     But it's good to be prepared in case they open a Marble Hill McDonald's.

psql -h 127.0.0.1 -d mctrot << SQL

CREATE OR REPLACE VIEW mcisland AS

WITH chunk AS
(SELECT
  borough.boro_code,
  borough.boro_name,
  (ST_DUMP(borough.the_geog::geometry)).geom
FROM borough)

SELECT
  row_number() over() as id,
  chunk.boro_code,
  chunk.boro_name,
  ST_TRANSFORM(chunk.geom, 4326)::geography as the_geog
FROM chunk
INNER JOIN mcd
ON ST_CONTAINS(chunk.geom, mcd.the_geog::geometry)
AND chunk.boro_name = 'Manhattan'
GROUP BY
  chunk.boro_code,
  chunk.boro_name,
  ST_TRANSFORM(chunk.geom, 4326)::geography

SQL
