{ pkgs, utils, ... }:
let
  deviceUnit = "${utils.escapeSystemdPath "/dev/disk/by-label/warbler-actions"}.device";
  sata = "/var/lib/warbler-sata";
in
{
  # Keep the existing LUKS label, mapper name, and key location.
  systemd.services.actions-vm-storage = {
    description = "Unlock Warbler SATA storage";
    requires = [ deviceUnit ];
    after = [ deviceUnit ];
    unitConfig.RequiresMountsFor = [ "/persist/var/lib/actions-vm-storage" ];
    script = ''
      ${pkgs.cryptsetup}/bin/cryptsetup status warbler-actions >/dev/null 2>&1 || \
        ${pkgs.cryptsetup}/bin/cryptsetup open --key-file /persist/var/lib/actions-vm-storage/key /dev/disk/by-label/warbler-actions warbler-actions
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStop = "${pkgs.cryptsetup}/bin/cryptsetup close warbler-actions";
    };
  };
  fileSystems.${sata} = {
    device = "/dev/mapper/warbler-actions";
    fsType = "btrfs";
    options = [ "compress=zstd" "noatime" "nodev" "nosuid" "nofail" "x-systemd.requires=actions-vm-storage.service" ];
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
  systemd.tmpfiles.rules = [
    "d /var/lib/actions-vm/state 0700 actions-vm-scaler-windows actions-vm-scaler-windows -"
  ];
}
