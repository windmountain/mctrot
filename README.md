# McTrot Tools

McTrot is an annual personal challenge to eat at every McDonald's in Manhattan, on foot, in less than 24 hours.

This repo contains tools for:
  - downloading current McDonald's locations from their API
  - researching and cataloging historical McDonald's locations from microfiche at NYPL
  - making a map
    - downloading geospatial layers from NYC Open Data
    - massaging layers into Postgres views
    - designing the map in QGIS
  - etc

This repository manages its external dependencies (gdal, postgres, jq, etc.) with [devenv.sh](https://devenv.sh).

Here's a screenshot of the work in progress map:

![Simple map of Manhattan with yellow diamonds, red diamonds, and gray dots](/inprogress.png)

See also: [maps from previous years](/previous-mctrot-maps/) before GIS.

# Fetching data

The data dependencies of this map are listed in datapackage.json [spec](https://datapackage.org/standard/data-package/).

For some of these dependencies, you will need an account with NYC Open Data. Follow these steps:
    - Copy the .env.example file to a new file named .env.
    - Visit [their sign up page](https://data.cityofnewyork.us/signup) and sign up.
    - Verify your email address.
    - Go to [Developer Settings](https://data.cityofnewyork.us/profile/edit/developer_settings).
    - Click the "Create new API Key" button. Give it a name.
    - Fill in your .env file with your new API Key ID and Api Key Secret.

Once set up, fetch the data by running the fetch.py Python script.

# Postgres import

Start Postgres with `devenv up`

Connect to postgres on 127.0.0.1:5432/mctrot with your favorite client


Run `devenv shell` and then `./scripts/load.sh` to import data and make map-specific Postgres views

Download and open QGIS, create a new project, open the Data Source Manager window and a new Postgres connection with these details:

  - name: mctrot
  - host: 127.0.0.1
  - port: 5432
  - database: mctrot

Choose tables to add into the project.
