{ config, lib, pkgs, ... }:

{
  networking.hostName = "recorder";
  time.timeZone = "America/New_York";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Only SSH and web traffic get in. DigitalOcean's Cloud Firewall mirrors
  # this (SSH limited to my IP there).
  networking.firewall.allowedTCPPorts = [ 22 80 443 ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # The only way in. Deploys (`nix run .#deploy`) SSH in as root.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO7Jgkt1Qinux6JxO4eh3pL+E5BRYrUM+XF2uE4h+xPK zach@windmountainsoftware.com"
  ];

  # Logs (with visitors' IP addresses: Caddy, the API, Icecast) are kept
  # 14 days, as the privacy policy (website/privacy.html) promises.
  services.journald.extraConfig = ''
    MaxRetentionSec=14day
  '';

  # Small box: keep old generations around for rollback, but not forever.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  boot.loader.grub.configurationLimit = 10;

  # Before going live, set this to true and deploy: it protects event data
  # (no mctrot-wipe or mctrot-dislocate, no database reset on a schema
  # change). See host/recorder.nix.
  recorder.live = true;

  # The route plan: the simulator's GPX download, saved next to this
  # folder's flake.nix (or a hand-written GPX for a test walk). See
  # host/recorder.nix. Without it, Visit taps have no stores to match.
  recorder.routePlan = ../route-plan.gpx;

  system.stateVersion = "26.05";
}
