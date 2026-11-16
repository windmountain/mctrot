{ ... }:

{
  # The Droplet's own disk, partitioned by nixos-anywhere at install time.
  # Only the OS lives here: reinstalling wipes it, and that's fine.
  # BIOS boot + ESP so GRUB works whether the Droplet boots legacy or UEFI.
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/vda";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02";
        };
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  # The data Volume is deliberately NOT in disko: disko formats what it
  # declares, and the Volume must survive reinstalls. See digitalocean.nix.
}
