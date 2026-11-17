{ pkgs, utils, ... }:
let
  deviceUnit = "${utils.escapeSystemdPath "/dev/disk/by-label/warbler-actions"}.device";
in
{
  # Separate LUKS volume provisioned on the unused SATA SSD. Its unlock key
  # lives only on the already encrypted persistent system filesystem.
  systemd.services.actions-vm-storage = {
    description = "Unlock Actions VM storage";
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
  fileSystems."/var/lib/actions-vm" = {
    device = "/dev/mapper/warbler-actions";
    fsType = "btrfs";
    options = [ "compress=zstd" "noatime" "nodev" "nosuid" "nofail" "x-systemd.requires=actions-vm-storage.service" ];
  };
  # Preserve the macOS base paths, including existing qcow2 backing references.
  fileSystems."/var/lib/actions-vm-images" = {
    device = "/var/lib/actions-vm/images/macos";
    fsType = "none";
    options = [ "bind" "nofail" "x-systemd.requires-mounts-for=/var/lib/actions-vm" ];
  };
  fileSystems."/var/lib/actions-vm-scaler-windows" = {
    device = "/var/lib/actions-vm/state";
    fsType = "none";
    options = [ "bind" "nofail" "x-systemd.requires-mounts-for=/var/lib/actions-vm" ];
  };
  systemd.tmpfiles.rules = [
    "d /var/lib/actions-vm/state 0700 actions-vm-scaler-windows actions-vm-scaler-windows -"
  ];
}
