{ config, lib, ... }:

{
  # Secrets live encrypted in secrets/recorder.yaml (see .sops.yaml for who
  # can read them). At boot, sops-nix decrypts them with the box's SSH host
  # key into /run/secrets/, root-only. Services get copies through systemd
  # credentials (LoadCredential), never through the Nix store.
  #
  # Reinstalling the Droplet creates a new host key: update the recorder
  # key in .sops.yaml, then `sops updatekeys secrets/recorder.yaml`.
  sops = {
    defaultSopsFile = ../secrets/recorder.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets.ingest-token = { };
    # Signs the upload page's session cookie (api/src/session.ts).
    secrets.session-secret = { };
    # Sends guests' sign-in codes (api/src/guests/mail.ts).
    secrets.mailgun-api-key = { };
  };
}
