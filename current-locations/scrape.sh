./scrape-downtown.sh > downtown-results.json
./scrape-uptown.sh > uptown-results.json
node ./massage.js > manhattan-mcdonalds-locations.geojson
