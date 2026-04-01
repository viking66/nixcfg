# Disk layout for gordula (Hetzner dedicated, 2x 1TB Samsung NVMe)
#
# LVM volume group spanning both drives:
#   boot:  1GB   (outside LVM, GRUB legacy BIOS)
#   root:  50GB
#   nix:   200GB
#   swap:  8GB
#   media: ~1.7TB (remainder)
#
# Legacy BIOS boot (not EFI) — Hetzner dedicated x86_64.
{ ... }:

{
  disko.devices = {
    disk = {
      nvme0 = {
        type = "disk";
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            bios = {
              size = "1M";
              type = "EF02"; # BIOS boot partition for GRUB
              priority = 1;
            };
            boot = {
              size = "1G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/boot";
              };
            };
            lvm = {
              size = "100%";
              content = {
                type = "lvm_pv";
                vg = "pool";
              };
            };
          };
        };
      };
      nvme1 = {
        type = "disk";
        device = "/dev/nvme1n1";
        content = {
          type = "gpt";
          partitions = {
            lvm = {
              size = "100%";
              content = {
                type = "lvm_pv";
                vg = "pool";
              };
            };
          };
        };
      };
    };

    lvm_vg = {
      pool = {
        type = "lvm_vg";
        lvs = {
          swap = {
            size = "8G";
            content = {
              type = "swap";
            };
          };
          root = {
            size = "50G";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
          nix = {
            size = "200G";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/nix";
            };
          };
          media = {
            size = "100%FREE";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/media";
            };
          };
        };
      };
    };
  };
}
