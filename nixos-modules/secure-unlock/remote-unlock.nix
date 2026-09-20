{ config, lib, ... }:
lib.mkIf (config.boot.secureUnlock.enable && config.boot.secureUnlock.remoteUnlock.enable) {
  boot.initrd.systemd = {
    # cryptsetup stays active while asking for a passphrase, so OnFailure
    # cannot trigger recovery. TPM auto-unlock does not create an ask.* file.
    paths.secure-unlock-recovery = {
      description = "Watch for an initrd disk passphrase request";
      wantedBy = [ "initrd.target" ];
      before = [ "initrd-switch-root.target" ];
      conflicts = [ "initrd-switch-root.target" ];
      unitConfig.DefaultDependencies = false;
      pathConfig.PathExistsGlob = "/run/systemd/ask-password/ask.*";
    };
    services.secure-unlock-recovery = {
      description = "Start recovery networking when a disk passphrase is needed";
      before = [ "initrd-switch-root.target" ];
      conflicts = [ "initrd-switch-root.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # A console answer may have unlocked root since the path fired. Keep
      # this service active even when skipping, to avoid retriggering it.
      script = ''
        if [ ! -e /dev/mapper/${config.boot.secureUnlock.mapperName} ]; then
          systemctl --no-block start secure-unlock-recovery.target
        fi
      '';
    };
    targets.secure-unlock-recovery = {
      description = "Initrd recovery networking";
      before = [ "initrd-switch-root.target" ];
      conflicts = [ "initrd-switch-root.target" ];
      unitConfig.DefaultDependencies = false;
    };
    services.sshd.wantedBy = lib.mkForce [ "secure-unlock-recovery.target" ];
    services.systemd-networkd.wantedBy = lib.mkForce [ "secure-unlock-recovery.target" ];
    services.systemd-network-generator.wantedBy = lib.mkForce [ "secure-unlock-recovery.target" ];
    # Otherwise netlink traffic can activate networkd before recovery starts.
    sockets.systemd-networkd.wantedBy = lib.mkForce [ ];
  };
}
