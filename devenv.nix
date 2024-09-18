{ pkgs, lib, config, inputs, ... }:

{
  packages = [
    pkgs.unixtools.script
    pkgs.pv
    pkgs.entr
    pkgs.gdal
    pkgs.git
    pkgs.jq
  ];

  scripts.hello.exec = ''
    echo "welcome to mctrot tools"
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
    uv.enable = true;
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

  # https://devenv.sh/services/
  services.postgres = {
    enable = true;
    package = pkgs.postgresql_16;
    initialDatabases = [{ name = "mctrot"; }];
    extensions = extensions: [
      extensions.postgis
      extensions.timescaledb
    ];
    listen_addresses = "127.0.0.1";
    port = 5432;
  };

  # https://devenv.sh/languages/
  # languages.nix.enable = true;

  # https://devenv.sh/pre-commit-hooks/
  # pre-commit.hooks.shellcheck.enable = true;

  # https://devenv.sh/processes/
  # processes.ping.exec = "ping example.com";

  # See full reference at https://devenv.sh/reference/options/
}
