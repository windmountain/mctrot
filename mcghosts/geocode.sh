IFS=$'\n';

rm /tmp/geocoded.csv 2> /dev/null;

for phonebook_address in $(cat mcghosts.csv | cut -d ',' -f4); do
  curl -s -G \
    --data-urlencode text="$phonebook_address, Manhattan, New York, NY" \
    https://geosearch.planninglabs.nyc/v2/autocomplete \
    | jq -r '.features[0].geometry.coordinates | reverse | @csv' \
    >>/tmp/geocoded.csv 2>&1;
done

echo "year, phonebook, name, address, phone_number, lat, lon" > mcghosts_geocoded.csv
paste -d',' mcghosts.csv /tmp/geocoded.csv >> mcghosts_geocoded.csv
