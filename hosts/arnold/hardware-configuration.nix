# Do not modify this file!  It was generated by ‘nixos-generate-config’
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [
      (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "aacraid" "nvme" "firewire_ohci" "usbhid" "usb_storage" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    {
      device = "mainrust/enc/root-tmp";
      fsType = "zfs";
    };

  fileSystems."/nix" =
    {
      device = "mainrust/enc/nix";
      fsType = "zfs";
    };

  fileSystems."/persist" =
    {
      device = "mainrust/enc/persist";
      fsType = "zfs";
    };

  fileSystems."/boot.d/0" =
    {
      device = "/dev/disk/by-uuid/6F1B-13E7";
      fsType = "vfat";
      options = [ "fmask=0137" "dmask=0022" ];
    };

  fileSystems."/boot.d/1" =
    {
      device = "/dev/disk/by-uuid/6EC1-2C8B";
      fsType = "vfat";
      options = [ "fmask=0137" "dmask=0022" ];
    };

  swapDevices = [ ];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.enp0s31f6.useDHCP = lib.mkDefault true;
  # networking.interfaces.enp12s0.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
