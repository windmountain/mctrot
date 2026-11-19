{ config, lib, pkgs, ... }:

{
  # Caddy terminates HTTPS for every recorder subdomain and gets its own
  # Let's Encrypt certificates. api. and media. are defined in api.nix,
  # radio. in radio.nix.
  services.caddy.enable = true;

  # Access logs hold visitors' IP addresses. NixOS would write them to
  # /var/log/caddy/ and keep them 90 days; instead every host's go to the
  # journal, which keeps 14 days (configuration.nix), as the privacy
  # policy (website/privacy.html) says.
  services.caddy.virtualHosts = lib.genAttrs [ "api.mctrot.nyc" "media.mctrot.nyc" "radio.mctrot.nyc" ] (_: {
    logFormat = lib.mkDefault "output stderr";
  });
}
