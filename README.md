# McTrot Tools

McTrot is an annual personal challenge to eat at every McDonald's in Manhattan, on foot, in less than 24 hours.

This repo contains tools for:
  - downloading current McDonald's locations from their API
  - researching and cataloging historical McDonald's locations from microfiche at NYPL
  - making a map
    - downloading geospatial layers from NYC Open Data
    - massaging layers into Postgres views
    - designing the map in QGIS
  - keeping track of workouts for McTrot
  - etc

This repository manages its external dependencies (gdal, postgres, jq, etc.) with [devenv.sh](https://devenv.sh).

The output of the scraping and mcghosts projects feed into the mapping project:

```
scraping ━━━━━┳━━━━━▶ mapping
              ┃
mcghosts ━━━━━┛
```

Here's a screenshot of the work in progress map:

![Simple map of Manhattan with yellow diamonds, red diamonds, and gray dots](/mapping/inprogress.png)
