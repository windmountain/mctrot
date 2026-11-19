{ config, lib, pkgs, ... }:

let
  cfg = config.recorder;
  dataDir = "/var/lib/mctrot";
  services = lib.escapeShellArgs cfg.dataServices;

  # Empties the Volume: back to the "fresh out of the box" state. Keeps
  # everything that isn't event data (config, secrets, SSH keys, HTTPS
  # certificates), so the box stays deployable. Run from the laptop with
  # `nix run .#wipe`, or on the box as `mctrot-wipe`.
  wipe = pkgs.writeShellApplication {
    name = "mctrot-wipe";
    runtimeInputs = with pkgs; [ coreutils findutils util-linux systemd ];
    text = ''
      data=${dataDir}
      if ${lib.boolToString cfg.live}; then
        echo "recorder.live is on: refusing to delete event data." >&2
        echo "Turn it off in host/configuration.nix and deploy first." >&2
        exit 1
      fi
      if ! mountpoint -q "$data"; then
        echo "$data is not mounted (is the Volume attached?); refusing." >&2
        exit 1
      fi

      shopt -s nullglob dotglob
      items=()
      for item in "$data"/*; do
        [ "$(basename "$item")" = lost+found ] || items+=("$item")
      done
      if [ ''${#items[@]} -eq 0 ]; then
        echo "$data is already empty."
      else
        echo "This deletes everything under $data on $(hostname):"
        du -sh "''${items[@]}"
      fi
      echo "Services stopped and restarted around it: ${services}"
      read -r -p 'Type "wipe" to continue: ' answer
      [ "$answer" = wipe ] || { echo "Aborted; nothing deleted."; exit 1; }

      systemctl stop ${services}
      find "$data" -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +
      systemctl start ${services}
      echo "Done: $data is empty and the services are back up."
    '';
  };
in
{
  options.recorder = {
    live = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        The event is on: protect its data. Refuses `mctrot-wipe` and
        `mctrot-dislocate`, and a schema change stops the API instead of
        setting the database aside.
      '';
    };
    guests = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Guest accounts: people sign in with an emailed code to like and
        comment on posts (api/src/guests/). Sends email through Mailgun,
        so it needs the mailgun-api-key secret. Off: the routes don't
        exist and nothing else changes.
      '';
    };
    dataServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Units that read or write ${dataDir}. mctrot-wipe stops them
        before emptying it and starts them again after. Each service's
        module adds itself here.
      '';
    };
    routePlan = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "../route-plan.gpx";
      description = ''
        The route plan: a GPX from the simulator's GPX download, whose
        waypoints are the stores Visit taps are matched against (see
        DESIGN.md, "Visits"). A hand-written GPX works for a test walk.
        Converted to JSON when the system is built (tools/route_plan.py).
        Null: no stores, so no tap can match.
      '';
    };
  };

  config.environment.systemPackages = [ wipe ];
}
