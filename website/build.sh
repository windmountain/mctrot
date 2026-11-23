#!/usr/bin/env bash
# Assembles the deployable site in build/: copies the public pages and
# assets (including geo/route-legs.json, which the simulator fetches for its
# GPX export, sim/, the simulator's own share image and manifest, and
# live-share/og.png, /live's share image), and
# compiles the Elm programs into build/js/: the simulator, the mega search
# page, the mega search's worker, and /live (alongside js/'s hand-written
# scripts).
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
# The McTrot 5 replay: its page, archive.json, og.png and media/
# (made by export-archive; see src/Live.elm). Only these, by name: nothing
# else in the folder is meant for the site.
mkdir -p build/archive/2026-11-21
cp archive/2026-11-21/index.html archive/2026-11-21/archive.json archive/2026-11-21/og.png build/archive/2026-11-21/
cp -R archive/2026-11-21/media build/archive/2026-11-21/
mkdir -p build/live-share
cp live-share/og.png build/live-share/
cp favicon.svg favicon.ico favicon-16.png favicon-32.png favicon-48.png \
  apple-touch-icon.png icon-192.png icon-512.png \
  site.webmanifest og-image.png robots.txt sitemap.xml _redirects build/

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
compile Live live

# The replay's (and /live's) scripts and stylesheets get their contents'
# fingerprint in the address (/js/live.js?v=3f9a…), so a browser never
# runs a stale copy it kept from before a change: a changed file has a new
# address.
for page in build/archive/2026-11-21/index.html build/live.html; do
  for asset in js/live.js js/pair-player.js css/style.css; do
    hash=$(shasum -a 256 "build/$asset" | cut -c1-10)
    sed -i.bak "s|\"/$asset\"|\"/$asset?v=$hash\"|" "$page"
  done
  rm "$page.bak"
done
