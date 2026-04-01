# Hardware configuration for gordula (Hetzner dedicated, bare metal)
# Intel i7-8700, 64GB RAM, 2x 1TB Samsung NVMe
{ config, lib, pkgs, ... }:

{
  boot.initrd.availableKernelModules = [
    "ahci"
    "xhci_pci"
    "nvme"
    "sd_mod"
    "sr_mod"
    "usbhid"   # KVM/IPMI console access
  ];

  # LVM support in initrd (required to mount root from LVM)
  boot.initrd.kernelModules = [ "dm-mod" "dm-snapshot" ];

  boot.kernelModules = [ "kvm-intel" ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
