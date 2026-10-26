#!/usr/bin/env bash
# Assembles the deployable site in build/: copies the public pages and
# assets, and compiles the Elm simulator to build/js/simulator.js.
# Run inside `devenv shell` (for elm and terser). Does not regenerate map
# data; run data/generate_map_data.py by hand when data/mctrot_map.svg changes.
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build
mkdir -p build/js

for page in *.html; do
  [ "$page" = "preview-studio.html" ] && continue
  cp "$page" build/
done

cp -R css build/
cp favicon.svg favicon.ico favicon-16.png favicon-32.png favicon-48.png \
  apple-touch-icon.png icon-192.png icon-512.png \
  site.webmanifest og-image.png build/

elm make src/Simulator.elm --optimize --output=build/js/simulator.unmin.js
terser build/js/simulator.unmin.js --compress 'pure_funcs=[F2,F3,F4,F5,F6,F7,F8,F9,A2,A3,A4,A5,A6,A7,A8,A9],pure_getters,keep_fargs=false,unsafe_comps,unsafe' --mangle \
  --output build/js/simulator.js
rm build/js/simulator.unmin.js
