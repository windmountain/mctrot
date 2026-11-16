{ config, lib, pkgs, ... }:

{
  # Caddy terminates HTTPS for every recorder subdomain and gets its own
  # Let's Encrypt certificates. api. and media. are defined in api.nix,
  # radio. in radio.nix.
  services.caddy.enable = true;
}
