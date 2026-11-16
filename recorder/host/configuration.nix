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

  # Small box: keep old generations around for rollback, but not forever.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  boot.loader.grub.configurationLimit = 10;

  system.stateVersion = "26.05";
}
