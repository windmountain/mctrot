Start Postgres with `devenv up`

Connect to postgres on 127.0.0.1:5432/mctrot with your favorite client

Read the 'sources.txt' file and download the geospatial data from those links into data

Run `devenv shell` and then `./scripts/load.sh` to import data and make map-specific Postgres views

Download and open QGIS, create a new project, open the Data Source Manager window and a new Postgres connection with these details:

  - name: mctrot
  - host: 127.0.0.1
  - port: 5432
  - database: mctrot

Choose tables to add into the project. 
