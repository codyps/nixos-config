{ config, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # Inspected over SSH on the installer; disk mounts are owned by disko.
  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "ehci_pci" "nvme" "usb_storage" "usbhid" "sd_mod" ];
  boot.initrd.kernelModules = [ "r8169" "rtw89_8852ae" ];
  boot.kernelModules = [ "kvm-amd" ];
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
