# McTrot Tools

McTrot is an annual personal challenge to eat at every McDonald's in Manhattan, on foot, in less than 24 hours.

This repo contains tools for:
- downloading current McDonald's locations from their API
- researching and cataloging historical McDonald's locations from microfiche at NYPL
- making a map
  - downloading geospatial layers from NYC Open Data
  - massaging layers into Postgres views
  - designing the map in QGIS
- computing a walking-distance cost matrix between every pair of locations by routing along sidewalk centerlines with pgRouting
- solving the TSP (travelling salesman problem) to find the shortest walking route that visits every location, using simulated annealing (`tsp.ipynb`)

This repository manages its external dependencies (gdal, postgres, jq, etc.) with [devenv.sh](https://devenv.sh).

Here's a screenshot of the work in progress map:

<img src="/inprogress.png" width="200px" alt="Simple map of Manhattan with yellow diamonds, red diamonds, and gray dots">

See also: [maps from previous years](/previous-mctrot-maps/) before GIS.

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

Much of this project is concerned with loading data into Postgres, using views to filter what's relevant for McTrot, and bringing those views into QGIS for designing an actual map. Loading data directly into QGIS just uses way too much memory and is too slow.

~~Start Postgres with `devenv up`~~ Running Postgres from devenv is disabled because the pgrouting extension there is busted. Try [Postgres.app](https://postgresapp.com) if you're on a Mac. If you're not on a Mac, there are [many other options](https://www.postgresql.org/download/). The main thing is you want a local server running on the default port.

Run `devenv shell` and then `./scripts/load.sh` to set up the mctrot database, import data from data/, and make map-specific views.

Download and open [QGIS](https://qgis.org), create a new project, open the Data Source Manager window and a new Postgres connection with these details:

- name: mctrot
- host: 127.0.0.1
- port: 5432
- database: mctrot

Choose tables to add into the project.

# TSP notebook

`tsp.ipynb` loads the `route_summary` cost matrix from Postgres and uses simulated annealing to find an approximate shortest route visiting every Manhattan McDonald's.

Python dependencies are declared in `pyproject.toml`. To install them and launch the notebook:

```
uv sync
uv run jupyter lab
```
