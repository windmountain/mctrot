{ config, lib, pkgs, ... }:

{
  # Caddy terminates HTTPS for every recorder subdomain and gets its own
  # Let's Encrypt certificates. For now it only says hello on api.;
  # radio. and media. arrive in later steps.
  services.caddy = {
    enable = true;
    virtualHosts."api.mctrot.nyc".extraConfig = ''
      respond "hello from mctrot" 200
    '';
  };
}
