{ config, pkgs, version, ... }:

let
  api = pkgs.callPackage ../api/package.nix { };
  port = 3000;
in
{
  users.users.mctrot = {
    isSystemUser = true;
    group = "mctrot";
  };
  users.groups.mctrot = { };

  systemd.services.mctrot-api = {
    description = "McTrot recorder API";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    # Never start against the root disk if the Volume isn't mounted.
    unitConfig.RequiresMountsFor = "/var/lib/mctrot";

    environment = {
      HOST = "127.0.0.1";
      PORT = toString port;
      MCTROT_DB = "/var/lib/mctrot/db/recorder.sqlite";
      MCTROT_VERSION = version;
      NODE_ENV = "production";
    };

    serviceConfig = {
      ExecStart = "${api}/bin/mctrot-api";
      User = "mctrot";
      Group = "mctrot";
      # Creates /var/lib/mctrot/db on the Volume, owned by mctrot.
      StateDirectory = "mctrot/db";
      StateDirectoryMode = "0750";
      LoadCredential = [
        "ingest-token:${config.sops.secrets.ingest-token.path}"
      ];
      Restart = "always";
      RestartSec = 2;

      # The API needs its database directory and the network, nothing else.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      RestrictNamespaces = true;
      LockPersonality = true;
      # No MemoryDenyWriteExecute: V8's JIT needs writable+executable memory.
    };
  };

  services.caddy.virtualHosts."api.mctrot.nyc".extraConfig = ''
    reverse_proxy 127.0.0.1:${toString port}
  '';
}
