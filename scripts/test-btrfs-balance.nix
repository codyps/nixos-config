{ nixpkgs }:
let
  system = fileSystems: extra: import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      ../nixos-modules/btrfs-balance.nix
      { inherit fileSystems; system.stateVersion = "26.05"; }
      extra
    ];
  };
  fs = fsType: { inherit fsType; device = "/dev/fixture"; };
  btrfs = (system { "/" = fs "btrfs"; "/home" = fs "btrfs"; "/boot" = fs "vfat"; } { }).config;
  ext4 = (system { "/" = fs "ext4"; } { }).config;
  disabled = (system { "/" = fs "btrfs"; } { services.btrfs.autoBalance.enable = false; }).config;
  overridden = (system { "/" = fs "btrfs"; } { services.btrfs.autoBalance.interval = "daily"; }).config;
in
assert btrfs.services.btrfs.autoBalance.enable;
assert btrfs.services.btrfs.autoBalance.fileSystems == [ "/" "/home" ];
assert btrfs.systemd.timers.btrfs-balance.timerConfig.OnCalendar == "weekly";
assert btrfs.systemd.timers.btrfs-balance.timerConfig.Persistent;
assert btrfs.systemd.services.btrfs-balance.serviceConfig.Nice == 19;
assert !ext4.services.btrfs.autoBalance.enable;
assert !(ext4.systemd.timers ? btrfs-balance);
assert !(disabled.systemd.services ? btrfs-balance);
assert overridden.systemd.timers.btrfs-balance.timerConfig.OnCalendar == "daily";
{
  btrfsEnabled = true;
  otherFilesystemsDisabled = true;
  optOut = true;
  scheduleOverride = true;
}
