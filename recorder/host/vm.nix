{ config, lib, pkgs, ... }:

{
  # Settings that apply only to the local test VM built by
  # `nix run .#vm` (nixos-rebuild build-vm). The real Droplet ignores this.
  virtualisation.vmVariant = {
    virtualisation = {
      memorySize = 2048;
      cores = 2;
      graphics = false;
      forwardPorts = [
        { from = "host"; host.port = 8080; guest.port = 80; }
        { from = "host"; host.port = 2222; guest.port = 22; }
      ];
    };

    # QEMU's user network speaks DHCP and has no DigitalOcean config drive.
    networking.useDHCP = lib.mkOverride 40 true; # beats digitalocean.nix's mkForce
    services.cloud-init.enable = lib.mkForce false;

    # No domain or certificates locally: answer plain HTTP on any host name.
    services.caddy.virtualHosts = lib.mkForce {
      ":80".extraConfig = ''
        respond "hello from mctrot (local VM)" 200
      '';
    };

    # Console login for poking around the VM. Never set on the real box.
    users.users.root.initialPassword = "recorder";
  };
}
