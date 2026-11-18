{ config, lib, pkgs, ... }:

# The radio: Liquidsoap makes the stream and sends it to Icecast, which
# serves it to listeners at https://radio.mctrot.nyc/live.mp3 (through
# Caddy). Both listen only on 127.0.0.1; Caddy passes on the stream and
# nothing else, so Icecast's admin pages aren't reachable from outside.
#
# The show (station/program.liq): one long file and its program.json,
# made by tools/radio_program.py and uploaded by hand to `station`, not
# deployed (they're gigabytes, and change without a deploy). A new
# program.json restarts Liquidsoap, which picks up the show where the
# clock says it is.
let
  port = 8000;

  station = "/var/lib/mctrot/station";

  # The holding loop, synthesized at build time: ten seconds of lounge
  # music that loops without a seam (station/holding.py).
  holding = pkgs.runCommand "mctrot-holding.wav" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 ${../station/holding.py} $out
  '';

  script = pkgs.replaceVars ../station/program.liq {
    inherit station holding;
    port = toString port;
  };

  # Icecast's settings, with the passwords filled in by sops-nix when the
  # box starts (see sops.templates below), so they never sit in the store.
  icecastXml = ''
    <icecast>
      <location>New York</location>
      <admin>radio@mctrot.nyc</admin>
      <hostname>radio.mctrot.nyc</hostname>
      <limits>
        <clients>500</clients>
        <sources>2</sources>
        <queue-size>524288</queue-size>
        <burst-size>65536</burst-size>
      </limits>
      <authentication>
        <source-password>${config.sops.placeholder.icecast-source}</source-password>
        <admin-user>admin</admin-user>
        <admin-password>${config.sops.placeholder.icecast-admin}</admin-password>
      </authentication>
      <listen-socket>
        <port>${toString port}</port>
        <bind-address>127.0.0.1</bind-address>
      </listen-socket>
      <mount type="normal">
        <mount-name>/live.mp3</mount-name>
        <public>0</public>
      </mount>
      <fileserve>1</fileserve>
      <paths>
        <logdir>/var/log/icecast</logdir>
        <webroot>${pkgs.icecast}/share/icecast/web</webroot>
        <adminroot>${pkgs.icecast}/share/icecast/admin</adminroot>
      </paths>
      <logging>
        <accesslog>-</accesslog>
        <errorlog>-</errorlog>
        <loglevel>2</loglevel>
      </logging>
      <security>
        <chroot>0</chroot>
      </security>
    </icecast>
  '';

  # The station's small website: a home page listing the stream and the
  # playlists, and the playlists themselves, for players that want a
  # playlist link. Files rather than inline text: a Caddyfile treats
  # #EXTM3U as a comment.
  playlists = pkgs.linkFarm "mctrot-radio-site" [
    {
      name = "index.html";
      path = pkgs.writeText "index.html" ''
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>McTrot radio</title>
          <meta name="robots" content="noindex">
          <style>
            body { font: 1.05rem/1.5 -apple-system, Helvetica, Arial, sans-serif; max-width: 34rem; margin: 2rem auto; padding: 0 16px; color: #0D0D08; background: #fff; }
            h1 { margin: 0 0 0.5rem; }
            dt { font-weight: bold; margin-top: 1rem; }
            dd { margin: 0.2rem 0 0; overflow-wrap: anywhere; }
            code { font-size: 0.95em; }
            .note { color: #6b6648; font-size: 0.9em; }
            @media (prefers-color-scheme: dark) { body { color: #f2f0e6; background: #111; } a { color: #FFD100; } .note { color: #b8b39a; } }
          </style>
        </head>
        <body>
          <h1>McTrot radio</h1>
          <p>The soundtrack to a walk to every McDonald’s in Manhattan. Listen along on <a href="https://mctrot.nyc/live">mctrot.nyc/live</a>, or in any radio app with one of these:</p>
          <dl>
            <dt>Stream (MP3, 128 kbps)</dt>
            <dd><a href="/live.mp3"><code>https://radio.mctrot.nyc/live.mp3</code></a></dd>
            <dt>Playlist (M3U)</dt>
            <dd><a href="/live.m3u"><code>https://radio.mctrot.nyc/live.m3u</code></a></dd>
            <dt>Playlist (PLS)</dt>
            <dd><a href="/live.pls"><code>https://radio.mctrot.nyc/live.pls</code></a></dd>
          </dl>
          <p class="note">VLC, Apple Music (File › Open Stream URL) and most radio apps take the stream URL; some older players want a playlist.</p>
        </body>
        </html>
      '';
    }
    {
      name = "live.m3u";
      path = pkgs.writeText "live.m3u" ''
        #EXTM3U
        #EXTINF:-1,McTrot radio
        https://radio.mctrot.nyc/live.mp3
      '';
    }
    {
      name = "live.pls";
      path = pkgs.writeText "live.pls" ''
        [playlist]
        NumberOfEntries=1
        File1=https://radio.mctrot.nyc/live.mp3
        Title1=McTrot radio
        Length1=-1
        Version=2
      '';
    }
  ];

  hardening = {
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
in
{
  sops.secrets.icecast-source = { };
  sops.secrets.icecast-admin = { };
  sops.templates."icecast.xml".content = icecastXml;

  systemd.services.icecast = {
    description = "Icecast: serves the McTrot radio stream";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    restartTriggers = [ config.sops.templates."icecast.xml".content ];
    serviceConfig = hardening // {
      DynamicUser = true;
      LoadCredential = [ "icecast.xml:${config.sops.templates."icecast.xml".path}" ];
      # %d: this unit's credentials directory.
      ExecStart = "${pkgs.icecast}/bin/icecast -c %d/icecast.xml";
      LogsDirectory = "icecast";
      Restart = "always";
      RestartSec = 2;
    };
  };

  # Where the show is uploaded: root's (scp as root), readable by
  # Liquidsoap and the API.
  systemd.tmpfiles.rules = [ "d ${station} 0755 root root -" ];

  systemd.services.mctrot-radio = {
    description = "McTrot radio: Liquidsoap, streaming to Icecast";
    wantedBy = [ "multi-user.target" ];
    after = [ "icecast.service" ];
    wants = [ "icecast.service" ];
    unitConfig.RequiresMountsFor = "/var/lib/mctrot";
    # Liquidsoap type-checks its whole library at start (about 12 s on one
    # CPU) unless it can keep the result: a cache cuts restarts to a second
    # or two, which is how long the stream is down after a deploy or crash.
    environment = {
      LIQ_CACHE_USER_DIR = "/var/cache/mctrot-radio";
      LIQ_CACHE_SYSTEM_DIR = "/var/cache/mctrot-radio";
    };
    serviceConfig = hardening // {
      DynamicUser = true;
      CacheDirectory = "mctrot-radio";
      LoadCredential = [ "icecast-source:${config.sops.secrets.icecast-source.path}" ];
      ExecStart = "${pkgs.liquidsoap}/bin/liquidsoap ${script}";
      Restart = "always";
      RestartSec = 2;
      # Ahead of everything else for the CPU: the stream must never stutter.
      Nice = -5;
    };
  };

  # A new program.json (the upload's last file) restarts the radio, which
  # reads it at start. PathChanged fires when the file is closed after
  # writing, so a half-copied one isn't read.
  systemd.paths.mctrot-radio-program = {
    description = "Watch McTrot radio's program.json";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "${station}/program.json";
      Unit = "mctrot-radio-reload.service";
    };
  };

  systemd.services.mctrot-radio-reload = {
    description = "McTrot radio: restart on a new program";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl restart mctrot-radio.service";
    };
  };

  # The stream, and playlists pointing at it for players that prefer a
  # playlist link (Winamp, iTunes, some radio apps). Browsers need the
  # stream itself. Anything else gets a short note.
  services.caddy.virtualHosts."radio.mctrot.nyc".extraConfig = ''
    handle /live.mp3 {
      reverse_proxy 127.0.0.1:${toString port} {
        # Send audio on as it arrives, not in buffered chunks.
        flush_interval -1
      }
    }
    handle /live.m3u {
      header Content-Type "audio/x-mpegurl"
      root * ${playlists}
      file_server
    }
    handle /live.pls {
      header Content-Type "audio/x-scpls"
      root * ${playlists}
      file_server
    }
    # The home page, at / (http:// redirects here: Caddy does that for
    # every site).
    handle / {
      root * ${playlists}
      file_server
    }
    handle {
      respond "Not here. McTrot radio: https://radio.mctrot.nyc/" 404
    }
  '';
}
