{ ... }:
let
  sata = "/var/lib/warbler-sata";
in
{
  environment.etc.crypttab = {
    mode = "0600";
    text = ''
      warbler-actions /dev/disk/by-label/warbler-actions /persist/var/lib/actions-vm-storage/key luks,noauto,nofail,headless=yes
    '';
  };
  fileSystems.${sata} = {
    device = "/dev/mapper/warbler-actions";
    fsType = "btrfs";
    options = [ "compress=zstd" "noatime" "nodev" "nosuid" "nofail" ];
  };
  # Keep build, media, and published Windows image paths valid.
  fileSystems."/var/lib/actions-vm" = {
    device = sata;
    fsType = "none";
    options = [ "bind" "nofail" "x-systemd.requires-mounts-for=${sata}" ];
  };
  # Preserve the macOS base paths, including existing qcow2 backing references.
  fileSystems."/var/lib/actions-vm-images" = {
    device = "${sata}/images/macos";
    fsType = "none";
    options = [ "bind" "nofail" "x-systemd.requires-mounts-for=${sata}" ];
  };
  fileSystems."/var/lib/actions-vm-scaler-windows" = {
    device = "${sata}/state";
    fsType = "none";
    options = [ "bind" "nofail" "x-systemd.requires-mounts-for=${sata}" ];
  };
}
