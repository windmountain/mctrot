{ lib, modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot = {
    loader.grub = {
      efiSupport = true;
      efiInstallAsRemovable = true;
    };
    initrd.kernelModules = [ "virtio_scsi" ];
    kernelParams = [ "console=ttyS0" ];
  };

  # DigitalOcean hands out public addresses through cloud-init's config
  # drive, not DHCP. cloud-init only configures the network here; SSH keys
  # come from configuration.nix.
  networking.useDHCP = lib.mkForce false;
  services.cloud-init = {
    enable = true;
    network.enable = true;
    settings = {
      datasource_list = [ "ConfigDrive" ];
      datasource.ConfigDrive = { };
    };
  };

  # The attached Volume holds everything that must outlive the OS: SQLite,
  # media, broadcast recordings. Create it in the console as
  # `recorder-data` with "Automatically Format & Mount" (ext4); the name
  # fixes this device path. `nofail` lets the box boot (and be fixed over
  # SSH) if the Volume is ever detached.
  fileSystems."/var/lib/mctrot" = {
    device = "/dev/disk/by-id/scsi-0DO_Volume_recorder-data";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=30s" "noatime" ];
  };
}
