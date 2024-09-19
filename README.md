# McTrot Tools

Tools and stuff for:
  - downloading current McDonald's locations from their API
  - researching and cataloging historical McDonald's locations from microfiche at NYPL
  - keeping track of workouts for McTrot
  - etc

This repository manages its external dependencies (gdal, postgres, jq, etc.) with [devenv.sh](https://devenv.sh).

The output of the scraping and mcghosts projects feed into the mapping project:

```
scraping ━━━━━┳━━━━━▶ mapping
              ┃
mcghosts ━━━━━┛
```
