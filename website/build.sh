#!/usr/bin/env bash
# Assembles the deployable site in build/: copies the public pages and
# assets (including geo/route-legs.json, which the simulator fetches for its
# GPX export, and sim/, the simulator's own share image and manifest), and
# compiles the Elm programs into build/js/: the simulator, the mega search
# page, and the mega search's worker (alongside js/'s hand-written scripts).
# Run inside `devenv shell` (for elm and terser). Does not regenerate map
# data; run scripts/export_simulator_data.py for that (see README).
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build
mkdir -p build/js

for page in *.html; do
  [ "$page" = "preview-studio.html" ] && continue
  cp "$page" build/
done

cp -R css geo sim build/
cp favicon.svg favicon.ico favicon-16.png favicon-32.png favicon-48.png \
  apple-touch-icon.png icon-192.png icon-512.png \
  site.webmanifest og-image.png robots.txt sitemap.xml build/

cp js/*.js build/js/

# Each Elm program, optimized and minified.
compile() {
  elm make "src/$1.elm" --optimize --output="build/js/$2.unmin.js"
  terser "build/js/$2.unmin.js" --compress 'pure_funcs=[F2,F3,F4,F5,F6,F7,F8,F9,A2,A3,A4,A5,A6,A7,A8,A9],pure_getters,keep_fargs=false,unsafe_comps,unsafe' --mangle \
    --output "build/js/$2.js"
  rm "build/js/$2.unmin.js"
}

compile Simulator simulator
compile MegaSearch mega-search
compile MegaSearchWorker mega-search-worker-elm
