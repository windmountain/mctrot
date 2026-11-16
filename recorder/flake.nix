{
  description = "McTrot recorder: the ephemeral server behind mctrot.nyc/live";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Where the box answers SSH once DNS is in place. Install (first time)
      # takes the bare IP instead, since DNS may not have propagated.
      host = "root@recorder.mctrot.nyc";

      # NB: `${./.}`, not `${self}`: when the flake is read from git,
      # self points at the repo root, which has no flake.nix.
      # Laptop-side tools, runnable from macOS or Linux. Both build on the
      # Droplet itself, so a Mac needs no Linux builder.
      forLaptops = f: nixpkgs.lib.genAttrs
        [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ]
        (s: f nixpkgs.legacyPackages.${s});

      laptopApps = lpkgs: {
        # First install over a stock Debian/Ubuntu Droplet. WIPES ITS DISK
        # (not the Volume). Usage: nix run .#install -- <droplet-ip>
        install = {
          type = "app";
          program = toString (lpkgs.writeShellScript "recorder-install" ''
            set -eu
            ip="''${1:?usage: nix run .#install -- <droplet-ip>}"
            exec ${lpkgs.nixos-anywhere}/bin/nixos-anywhere \
              --flake "path:${./.}#recorder" \
              --build-on remote \
              --target-host "root@$ip"
          '');
        };

        # Every later change. Usage: nix run .#deploy [-- <target>]
        deploy = {
          type = "app";
          program = toString (lpkgs.writeShellScript "recorder-deploy" ''
            set -eu
            target="''${1:-${host}}"
            exec ${lpkgs.nixos-rebuild-ng}/bin/nixos-rebuild switch \
              --flake "path:${./.}#recorder" \
              --target-host "$target" \
              --build-host "$target"
          '');
        };
      };
    in
    {
      # The one machine: a DigitalOcean Droplet in NYC, installed with
      # nixos-anywhere. `nix run .#vm` runs the same config locally.
      nixosConfigurations.recorder = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          disko.nixosModules.disko
          ./host/configuration.nix
          ./host/disko.nix
          ./host/digitalocean.nix
          ./host/caddy.nix
          ./host/vm.nix
        ];
      };

      apps = forLaptops laptopApps // {
        ${system} = laptopApps pkgs // {
          # `nix run .#vm` boots the recorder in QEMU with its port 80
          # forwarded to localhost:8080. Then: `curl localhost:8080`.
          vm = {
            type = "app";
            program = "${self.nixosConfigurations.recorder.config.system.build.vm}/bin/run-recorder-vm";
          };
        };
      };

      formatter = forLaptops (lpkgs: lpkgs.nixpkgs-fmt);
    };
}
