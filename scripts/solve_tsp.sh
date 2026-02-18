# there's probably a better way to integrate this into the project
#
# --stdout so the output can be piped to /dev/null and ignored
# --to slides because you have to pick something
# --execute to actually run the python notebook, which is the whole point of this
#
# after this runs, there should be 47 rows in tsp_route, or however McD's there are
# it would be nicer and less weird if the output just be a JSON result of the route,
# and that could be piped to a file and moved to the database in a different step

uv run jupyter nbconvert --stdout --to slides --execute tsp.ipynb >/dev/null
