{
  description = "McTrot recorder: the ephemeral server behind mctrot.nyc/live";

  inputs = {
    # The server's packages. NixOS channels only guarantee prebuilt Linux
    # binaries.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Same release for the laptop-side tools, with prebuilt macOS binaries
    # (otherwise a Mac compiles Node from source).
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-darwin, disko, sops-nix }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Shown by GET /health. Every commit changes it, so every deploy of a
      # new commit is visible; uncommitted changes show as "<rev>-dirty".
      version = self.shortRev or self.dirtyShortRev or "unknown";

      # Where the box answers SSH once DNS is in place. Install (first time)
      # takes the bare IP instead, since DNS may not have propagated.
      host = "root@recorder.mctrot.nyc";

      # Laptop-side tools, runnable from macOS or Linux.
      laptopSystems = [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ];
      forLaptops = f: nixpkgs.lib.genAttrs laptopSystems (s:
        f (if nixpkgs.lib.hasSuffix "darwin" s
        then nixpkgs-darwin.legacyPackages.${s}
        else nixpkgs.legacyPackages.${s}));

      # install and deploy read this flake from git, found from the current
      # directory, so `self` carries the commit for `version`. (The flake
      # can't name its own location: `${self}` is the repo root, and
      # `${./.}` is a copy without git history.) Both build on the Droplet,
      # so a Mac needs no Linux builder.
      findFlake = ''
        root=$(git rev-parse --show-toplevel 2>/dev/null) || {
          echo "run this from inside the mctrot repo" >&2; exit 1; }
        flake="git+file://$root?dir=recorder"
      '';

      laptopApps = lpkgs: {
        # First install over a stock Debian/Ubuntu Droplet. WIPES ITS DISK
        # (not the Volume). Usage: nix run .#install -- <droplet-ip>
        install = {
          type = "app";
          program = toString (lpkgs.writeShellScript "recorder-install" ''
            set -eu
            ip="''${1:?usage: nix run .#install -- <droplet-ip>}"
            ${findFlake}
            exec ${lpkgs.nixos-anywhere}/bin/nixos-anywhere \
              --flake "$flake#recorder" \
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
            ${findFlake}
            exec ${lpkgs.nixos-rebuild-ng}/bin/nixos-rebuild switch \
              --flake "$flake#recorder" \
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
        specialArgs = { inherit version; };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          ./host/configuration.nix
          ./host/disko.nix
          ./host/digitalocean.nix
          ./host/secrets.nix
          ./host/caddy.nix
          ./host/api.nix
          ./host/vm.nix
        ];
      };

      # `nix build .#api` builds and tests the API on this machine.
      packages = forLaptops (lpkgs: {
        api = lpkgs.callPackage ./api/package.nix { };
      });

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

      # `nix develop` (from recorder/): Node for the API, sops for secrets.
      devShells = forLaptops (lpkgs: {
        default = lpkgs.mkShell {
          packages = [ lpkgs.nodejs_26 lpkgs.sops lpkgs.ssh-to-age ];
        };
      });

      formatter = forLaptops (lpkgs: lpkgs.nixpkgs-fmt);
    };
}
