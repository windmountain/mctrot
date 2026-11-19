{ config, lib, pkgs, version, ... }:

let
  api = pkgs.callPackage ../api/package.nix { };
  port = 3000;
  dbPath = "/var/lib/mctrot/db/recorder.sqlite";
  # On the Volume, owned by mctrot: the database, uploads waiting for the
  # worker, and the worker's output. Both services list all three (with
  # the same mode), so neither one's start changes the other's.
  stateDirs = [ "mctrot/db" "mctrot/uploads" "mctrot/media" ];
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

  recorder.dataServices = [
    "mctrot-api.service"
    "mctrot-worker.service"
    "mctrot-weather.timer"
    "mctrot-weather.service"
  ];

  # Caddy serves the media folder (media.mctrot.nyc, below); the group
  # lets it read there while the Volume's folders stay closed to others.
  users.users.caddy.extraGroups = [ "mctrot" ];

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
      # Finished uploads wait here for the worker; the worker's results are
      # served from media.mctrot.nyc.
      MCTROT_UPLOAD_DIR = "/var/lib/mctrot/uploads";
      MCTROT_MEDIA_URL = "https://media.mctrot.nyc";
      # The radio's program, for /live's now playing (host/radio.nix).
      MCTROT_RADIO_PROGRAM = "/var/lib/mctrot/station/program.json";
      # Deleting a post from the upload page deletes its files too.
      MCTROT_MEDIA_DIR = "/var/lib/mctrot/media";
      NODE_ENV = "production";
    } // lib.optionalAttrs config.recorder.guests {
      # Guest accounts (api/src/guests/): /live on the site calls them.
      MCTROT_GUESTS = "on";
      MCTROT_SITE_ORIGIN = "https://mctrot.nyc";
      # Mailgun's EU region; the sending domain's DNS is at Namecheap.
      MCTROT_MAILGUN_URL = "https://api.eu.mailgun.net";
      MCTROT_MAILGUN_DOMAIN = "mg.mctrot.nyc";
      MCTROT_MAIL_FROM = "McTrot <noreply@mg.mctrot.nyc>";
    };

    serviceConfig = {
      ExecStart = "${api}/bin/mctrot-api";
      User = "mctrot";
      Group = "mctrot";
      StateDirectory = stateDirs;
      StateDirectoryMode = "0750";
      LoadCredential = [
        "ingest-token:${config.sops.secrets.ingest-token.path}"
        "session-secret:${config.sops.secrets.session-secret.path}"
      ] ++ lib.optional config.recorder.guests
        "mailgun-api-key:${config.sops.secrets.mailgun-api-key.path}";
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

  # Turns uploads into the photos, video and voice notes /live shows
  # (api/src/worker.ts). Low priority, as DESIGN.md asks: processing a video
  # must never starve the radio of CPU or disk.
  systemd.services.mctrot-worker = {
    description = "McTrot media worker";
    wantedBy = [ "multi-user.target" ];
    # The API sets up the database's schema; the worker only uses it.
    after = [ "mctrot-api.service" ];
    unitConfig.RequiresMountsFor = "/var/lib/mctrot";
    path = [ pkgs.vips pkgs.ffmpeg-headless ];

    environment = {
      MCTROT_DB = dbPath;
      MCTROT_MEDIA_DIR = "/var/lib/mctrot/media";
      NODE_ENV = "production";
    };

    serviceConfig = {
      ExecStart = "${api}/bin/mctrot-worker";
      User = "mctrot";
      Group = "mctrot";
      StateDirectory = stateDirs;
      StateDirectoryMode = "0750";
      # Files it makes are readable by the group, so Caddy can serve them.
      UMask = "0027";
      Nice = 19;
      CPUQuota = "50%";
      IOSchedulingClass = "idle";
      Restart = "always";
      RestartSec = 5;

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateNetwork = true; # it only reads and writes files
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      LockPersonality = true;
    };
  };

  # The weather in central Manhattan, every 10 minutes, from Open-Meteo
  # (api/src/weather.ts). One fetch per run; a failed one is logged and the
  # next run tries again.
  systemd.services.mctrot-weather = {
    description = "McTrot weather fetch";
    after = [ "mctrot-api.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = "/var/lib/mctrot";
    environment = {
      MCTROT_DB = dbPath;
      NODE_ENV = "production";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${api}/bin/mctrot-weather";
      User = "mctrot";
      Group = "mctrot";
      StateDirectory = stateDirs;
      StateDirectoryMode = "0750";
      TimeoutStartSec = 60;

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
    };
  };

  systemd.timers.mctrot-weather = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/10"; # :00, :10, :20 …
      Persistent = true; # catch up once after a reboot or deploy
    };
  };

  environment.systemPackages = [ dislocate ];

  services.caddy.virtualHosts."api.mctrot.nyc".extraConfig = ''
    reverse_proxy 127.0.0.1:${toString port}
  '';

  # The worker's output, straight from disk. File names never change once
  # a post is ready, so browsers (and any CDN later) may keep them forever.
  # Range requests (video scrubbing) come with file_server.
  services.caddy.virtualHosts."media.mctrot.nyc".extraConfig = ''
    root * /var/lib/mctrot/media
    file_server
    header Cache-Control "public, max-age=31536000, immutable"
    header Access-Control-Allow-Origin *
  '';
}
