{ config, lib, pkgs, ... }:

{
  # Caddy terminates HTTPS for every recorder subdomain and gets its own
  # Let's Encrypt certificates. api. is defined in api.nix; radio. and
  # media. arrive in later steps.
  services.caddy.enable = true;
}
