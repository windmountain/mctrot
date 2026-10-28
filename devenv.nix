{ pkgs, lib, config, inputs, ... }:

{
  packages = [
    pkgs.unixtools.script
    pkgs.pv
    pkgs.entr
    pkgs.gdal
    pkgs.git
    pkgs.jq
    pkgs.postgresql_18 # for psql, see below note on services.postgres
    pkgs.elmPackages.elm # website/build.sh
    pkgs.elmPackages.elm-test
    pkgs.terser
  ];

  dotenv.enable = true;

  scripts.hello.exec = ''
    echo "welcome to mctrot tools"
  '';

  scripts.ss.exec = ''
    git status
  '';

  # Rebuild everything, in order: fetch data (always re-scraping McDonald's),
  # load the database from scratch, solve, analyze, export the map and the
  # website simulator's data, and build the website.
  #
  # Needs a local Postgres with PostGIS and pgRouting on 127.0.0.1:5432 (see
  # README), and .env credentials for NYC Open Data if any data is missing.
  #
  # Not included: naming new locations (interactive; see nickname-interview
  # below -- until then the simulator export uses their addresses), and
  # updating the McDonald's resource's hash and "accessed" date in
  # datapackage.json (fetch.py prints the new hash).
  scripts.run-all.exec = ''
    set -euo pipefail
    cd "$DEVENV_ROOT"

    step() { printf '\n==> %s\n' "$*"; }

    step "Scrape current McDonald's locations"
    bash scripts/fetch_mcds.sh

    step "Fetch any other missing data"
    uv run fetch.py

    step "Load the database"
    bash scripts/load.sh

    step "Solve TSP and TSPTW"
    bash scripts/solve_tsp.sh
    bash scripts/solve_tsptw_single.sh
    bash scripts/solve_tsptw_multi.sh

    step "Post-solve route segments and analytics"
    bash scripts/create_tsp_route_segments.sh
    bash scripts/create_tsptw_single_route_segments.sh
    bash scripts/create_tsptw_multi_route_segments.sh
    bash scripts/create_tsptw_multi_analytics.sh
    uv run scripts/chart_tsptw_multi_analytics.py

    step "Export the map"
    bash scripts/create_route_pair_segments.sh
    uv run scripts/export_map_svg.py

    step "Export the simulator's data"
    uv run scripts/export_simulator_data.py

    step "Build the website"
    bash website/build.sh

    step "Done"
  '';

  # Just the last step of run-all: assemble the deployable site in
  # website/build/ from what's already exported (see website/build.sh).
  scripts.build-website.exec = ''
    set -euo pipefail
    cd "$DEVENV_ROOT"

    bash website/build.sh
  '';

  # Interactively name (or rename) locations, then save every nickname to
  # data/nicknames.json -- committed, unlike the rest of data/, and not
  # managed by datapackage.json/fetch.py. Needs a loaded database (run-all).
  # Re-run run-all (or just the simulator export and website build) after.
  scripts.nickname-interview.exec = ''
    set -euo pipefail
    cd "$DEVENV_ROOT"

    uv run scripts/nickname_interview.py
    uv run scripts/dump_nicknames.py > data/nicknames.json.tmp
    mv data/nicknames.json.tmp data/nicknames.json
    echo "Saved data/nicknames.json"
  '';

  languages.javascript = {
    enable = true;
    npm = {
      enable = true;
      install.enable = true;
    };
  };

  languages.python = {
    enable = true;
    uv = {
      enable = true;
      sync.enable = true;
    };
  };

  enterShell = ''
    hello
    git --version
  '';

  # https://devenv.sh/tests/
  enterTest = ''
    echo "Running tests"
    git --version | grep "2.42.0"
  '';


  # The pgrouting extension isn't working under nix/devenv.
  # Until it is, I'm disabling services.postgres and using Postgres.app, which
  # runs a server on 127.0.0.1:5432 just like would be done here.
  # (Postgres.app comes with pgrouting.)
  services.postgres = {
    enable = false; # the part that disables this service
    package = pkgs.postgresql_18;
    initialDatabases = [{ name = "mctrot"; }];
    extensions = extensions: [
      extensions.postgis
      # extensions.pgrouting # not working, see above
    ];
    listen_addresses = "127.0.0.1";
  };

  # https://devenv.sh/languages/
  # languages.nix.enable = true;

  # https://devenv.sh/pre-commit-hooks/
  # pre-commit.hooks.shellcheck.enable = true;

  # https://devenv.sh/processes/
  # processes.ping.exec = "ping example.com";

  # See full reference at https://devenv.sh/reference/options/
}
