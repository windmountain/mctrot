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
  ];

  dotenv.enable = true;

  scripts.hello.exec = ''
    echo "welcome to mctrot tools"
  '';

  scripts.ss.exec = ''
    git status
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
