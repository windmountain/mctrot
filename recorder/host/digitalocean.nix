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
  # drive, not DHCP. cloud-init configures the network (which it does
  # outside the module lists below) and grows the root disk, nothing else:
  # the hostname, users and SSH keys come from this flake, and
  # DigitalOcean's vendor scripts assume Ubuntu and fail on NixOS.
  networking.useDHCP = lib.mkForce false;
  services.cloud-init = {
    enable = true;
    network.enable = true;
    settings = {
      datasource_list = [ "ConfigDrive" ];
      datasource.ConfigDrive = { };
      preserve_hostname = true;
      cloud_init_modules = [ "growpart" "resizefs" ];
      cloud_config_modules = [ ];
      cloud_final_modules = [ ];
    };
  };

  # The attached Volume holds everything that must outlive the OS: SQLite,
  # media, broadcast recordings. Create it in the console as
  # `recorder-data` with "Automatically Format & Mount" (ext4); the name
  # fixes this device path. `nofail` lets the box boot (and be fixed over
  # SSH) if the Volume is ever detached. `autoResize` grows the filesystem
  # to fill the Volume at every mount, so resizing in the console only
  # needs a reboot (or: systemctl start systemd-growfs@var-lib-mctrot).
  fileSystems."/var/lib/mctrot" = {
    device = "/dev/disk/by-id/scsi-0DO_Volume_recorder-data";
    fsType = "ext4";
    autoResize = true;
    options = [ "nofail" "x-systemd.device-timeout=30s" "noatime" ];
  };
}
