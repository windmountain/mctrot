# McTrot Tools

McTrot is an annual personal challenge to eat at every McDonald's in Manhattan, on foot, in one go. I've been doing this annually since 2022. Making a map has always been [part of the tradition](/about/previous-mctrot-maps/) and this repo is about making a souped-up GIS one for 2026.

(I am more a student of McDonald's than a straight-ahead fan, and also use the company as a springboard to learn about finance, management, and supply chains at [Hamburger Business Review](https://www.hamburgerbusinessreview.com/).)

This repo contains tools for:
- downloading current McDonald's locations from their API
- researching and cataloging historical McDonald's locations from microfiche at NYPL
- making a map
  - downloading geospatial layers from NYC Open Data
  - massaging layers into Postgres views
  - designing the map in QGIS
- computing a walking-distance cost matrix between every pair of locations by routing along sidewalk centerlines with pgRouting
- solving the TSP (travelling salesman problem) to find the shortest walking route that visits every location, using simulated annealing (`tsp.ipynb`)
- solving TSPTW (TSP with time windows) to find the shortest route at a given pace while making sure that they're all open when I get to them
- doing analysis on the TSPTW solutions per pace

This repository manages its external dependencies (gdal, postgres, jq, etc.) with [devenv.sh](https://devenv.sh).

# Fetching data

The data dependencies of this map are listed in datapackage.json. Datapackage is a [specification](https://datapackage.org/standard/data-package/) for documenting where data came from, how it's licensed, etc.

For some of these dependencies, you will need an account with NYC Open Data. Follow these steps:
- Copy the .env.example file to a new file named .env.
- Visit [their sign up page](https://data.cityofnewyork.us/signup) and sign up.
- Verify your email address.
- Go to [Developer Settings](https://data.cityofnewyork.us/profile/edit/developer_settings).
- Click the "Create new API Key" button. Give it a name.
- Fill in your .env file with your new API Key ID and Api Key Secret.

Once set up, fetch the data by running the fetch.py Python script.

# Postgres and QGIS

Much of this project is concerned with loading data into Postgres, using views to filter what's relevant for McTrot, and bringing those views into QGIS for designing an actual map. Loading data directly into QGIS makes things too sluggish.

~~Start Postgres with `devenv up`~~ Running Postgres from devenv is disabled because the pgrouting extension there is busted. Try [Postgres.app](https://postgresapp.com) if you're on a Mac. If you're not on a Mac, there are [many other options](https://www.postgresql.org/download/). The main thing is you want a local server running on the default port.

Run `devenv shell` and then `./scripts/load.sh` to set up the mctrot database, import data from data/, and make map-specific views.

Download and open [QGIS](https://qgis.org), create a new project, open the Data Source Manager window and a new Postgres connection with these details:

- name: mctrot
- host: 127.0.0.1
- port: 5432
- database: mctrot

Choose tables to add into the project. Each table makes a layer on the map, with settings for how it's drawn and labeled.

# Route optimization

Route optimization happens in two phases: loading (above), then solving. The solve step reads from the database and writes results back to it.

Python dependencies are declared in `pyproject.toml`. To install them:

```
uv sync
```

## Solving

Run one of the solve scripts to execute a notebook and write results to Postgres:

```
./scripts/solve_tsptw_single.sh
./scripts/solve_tsptw_multi.sh
```

Or open and run notebooks interactively with `uv run jupyter lab`.

## Post-solve analysis

After solving, run analysis scripts to derive summary tables from the results:

```
./scripts/create_tsptw_multi_route_segments.sh   # sidewalk segments for each pace's route
./scripts/create_tsptw_multi_analytics.sh        # per-pace analytics (length, total time, hours to close)
```

These depend on the solve having run first. The analytics script also prints a summary table to stdout.

To generate a PDF chart of the analytics:

```
uv run scripts/chart_tsptw_multi_analytics.py
```

This writes `tsptw_multi_analytics.pdf` to the project root with two line charts: route length and minimum hours to close, both by pace.

# A note on AI

This GIS endeavor began in 2024 with the usual kind of Googling around for stuff. In 2026 I started using Claude pretty heavily to build on what's here and go on side quests like the route optimization.
