{ config, lib, ... }:
lib.mkIf config.warbler.remoteUnlock.enable {
  boot.initrd.systemd = {
    # cryptsetup stays active while asking for a passphrase, so OnFailure
    # cannot trigger recovery. TPM auto-unlock does not create an ask.* file.
    paths.warbler-remote-unlock = {
      description = "Watch for an initrd disk passphrase request";
      wantedBy = [ "initrd.target" ];
      before = [ "initrd-switch-root.target" ];
      conflicts = [ "initrd-switch-root.target" ];
      unitConfig.DefaultDependencies = false;
      pathConfig.PathExistsGlob = "/run/systemd/ask-password/ask.*";
    };
    services.warbler-remote-unlock = {
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
        if [ ! -e /dev/mapper/cryptroot ]; then
          systemctl --no-block start warbler-remote-unlock.target
        fi
      '';
    };
    targets.warbler-remote-unlock = {
      description = "Initrd recovery networking";
      before = [ "initrd-switch-root.target" ];
      conflicts = [ "initrd-switch-root.target" ];
      unitConfig.DefaultDependencies = false;
    };
    services.sshd.wantedBy = lib.mkForce [ "warbler-remote-unlock.target" ];
    services.systemd-networkd.wantedBy = lib.mkForce [ "warbler-remote-unlock.target" ];
    services.systemd-network-generator.wantedBy = lib.mkForce [ "warbler-remote-unlock.target" ];
    # Otherwise netlink traffic can activate networkd before recovery starts.
    sockets.systemd-networkd.wantedBy = lib.mkForce [ ];
  };
}
