# Historical Locations

Finding past McDonald's locations in Manhattan.

## Scans

Scans were made at NYPL Stephen A Schwarzman from two sources:

  Manhattan Classified/Yellow Pages
  https://www.nypl.org/research/research-catalog/bib/b16141427

  Residential and Classified/Yellow Pages
  (Not cataloged electronically, must request from desk)
  https://libguides.nypl.org/telephone/manhattan

File names of the scans should indicate year and whether of yellow or white pages.

# Spreadsheet

Scans are manually entered into mcghosts.ods with LibreOffice Calc.

There's a sheet per year and phonebook (yellow or white pages).

There's a top sheet, 'combined_and_normalized' that has them collected and with some quick manual normalizing (e.g. "Broadway" to "Bway", "6Av" to "6 Av"). This may have been unnecessary given that the next step might figure it out, time will tell.

This top sheet is exported into CSV as historical-locations.csv.

# Geocoding

The script geocode.sh runs through mcghosts.csv and sends each street address to NYC Geosearch (https://geosearch.planninglabs.nyc) to grab a latitude and longitude.

The results are combined with mcghosts.csv into historical-locations-geocoded.csv.
