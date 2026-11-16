{ config, lib, pkgs, version, ... }:

let
  api = pkgs.callPackage ../api/package.nix { };
  port = 3000;
  dbPath = "/var/lib/mctrot/db/recorder.sqlite";
  services = lib.escapeShellArgs config.recorder.dataServices;

  # The route plan GPX as the JSON the API reads, converted at build time
  # (tools/route_plan.py), so the API never parses XML. A bad GPX fails the
  # deploy's build, before anything changes on the box.
  routePlanJson = pkgs.runCommand "route-plan.json" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 ${../tools/route_plan.py} ${config.recorder.routePlan} > $out
  '';

  # Moves every GPS point so the walk is centered on Union Square, keeping
  # its shape (api/src/dislocate.ts). Stops the services that use the data
  # around the change, so nothing writes points mid-move; Overland queues
  # meanwhile. Run from the laptop with `nix run .#dislocate`.
  dislocate = pkgs.writeShellApplication {
    name = "mctrot-dislocate";
    runtimeInputs = with pkgs; [ coreutils util-linux systemd ];
    text = ''
      if ${lib.boolToString config.recorder.live}; then
        echo "recorder.live is on: refusing to move event data." >&2
        exit 1
      fi
      if [ ! -e ${dbPath} ]; then
        echo "No database yet; nothing to move."
        exit 0
      fi
      # As the API's user, so any files SQLite creates stay writable by it.
      as_api() {
        runuser -u mctrot -- env MCTROT_DB=${dbPath} \
          ${api}/bin/mctrot-dislocate-db "$@"
      }

      as_api plan
      echo "Services stopped and restarted around it: ${services}"
      read -r -p 'Type "dislocate" to continue: ' answer
      [ "$answer" = dislocate ] || { echo "Aborted; nothing moved."; exit 1; }

      systemctl stop ${services}
      # Restart the services even if the move fails.
      restart() { systemctl start ${services}; }
      trap restart EXIT
      as_api apply
    '';
  };
in
{
  users.users.mctrot = {
    isSystemUser = true;
    group = "mctrot";
  };
  users.groups.mctrot = { };

  recorder.dataServices = [ "mctrot-api.service" ];

  systemd.services.mctrot-api = {
    description = "McTrot recorder API";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    # Never start against the root disk if the Volume isn't mounted.
    unitConfig.RequiresMountsFor = "/var/lib/mctrot";

    environment = {
      HOST = "127.0.0.1";
      PORT = toString port;
      MCTROT_DB = dbPath;
      # Unset when there's no route plan: the API runs with no stores.
      MCTROT_ROUTE_PLAN = lib.mkIf (config.recorder.routePlan != null) "${routePlanJson}";
      MCTROT_VERSION = version;
      # When the schema changes (SCHEMA_VERSION in api/src/schema.ts), the
      # API moves the old database aside as a .bak and starts empty, until
      # recorder.live is on; then it refuses to start instead.
      MCTROT_DB_RESET = if config.recorder.live then "never" else "allow";
      # The upload page (api.mctrot.nyc/post) and its passkeys. The
      # passkey's domain is mctrot.nyc, so it keeps working on any subdomain.
      MCTROT_ORIGIN = "https://api.mctrot.nyc";
      MCTROT_RP_ID = "mctrot.nyc";
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
        "session-secret:${config.sops.secrets.session-secret.path}"
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

  environment.systemPackages = [ dislocate ];

  services.caddy.virtualHosts."api.mctrot.nyc".extraConfig = ''
    reverse_proxy 127.0.0.1:${toString port}
  '';
}
