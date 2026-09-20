{ config, lib, pkgs, ... }:
let
  cfg = config.boot.secureUnlock;
in
lib.mkIf (cfg.enable && cfg.remoteUnlock.enable && cfg.remoteUnlock.tailscale.enable) {
  boot.initrd = {
    kernelModules = [ "tun" ];
    services.resolved.enable = true;
    secrets."/etc/credstore.encrypted/tailscale-state" = "${cfg.stateDirectory}/credstore.encrypted/tailscale-state";
    systemd = {
      contents."/etc/ssl/certs/ca-certificates.crt".source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      services.systemd-resolved.wantedBy = lib.mkForce [ "secure-unlock-recovery.target" ];
      storePaths = [
        "${pkgs.tailscale}/bin/tailscaled"
        "${pkgs.bash}/bin/bash"
        "${pkgs.iproute2}/bin/ip"
        "${pkgs.coreutils}/bin/install"
      ];
      services.secure-unlock-tailscale = {
        description = "Separate Tailscale identity for initrd SSH recovery";
        wantedBy = [ "secure-unlock-recovery.target" ];
        wants = [ "systemd-networkd.service" "systemd-resolved.service" "tpm2.target" ];
        after = [ "systemd-networkd.service" "systemd-resolved.service" "tpm2.target" "initrd-nixos-copy-secrets.service" ];
        before = [ "initrd-switch-root.target" ];
        conflicts = [ "initrd-switch-root.target" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "simple";
          UMask = "0077";
          RuntimeDirectory = "secure-unlock-tailscale";
          RuntimeDirectoryMode = "0700";
          LoadCredentialEncrypted = [ "tailscale-state:/etc/credstore.encrypted/tailscale-state" ];
          # Credentials are read-only. Each boot gets a writable RAM snapshot;
          # this state/socket is never shared with the stage-2 daemon.
          ExecStartPre = "${pkgs.coreutils}/bin/install -m 0600 %d/tailscale-state /run/secure-unlock-tailscale/tailscaled.state";
          ExecStart = "${pkgs.tailscale}/bin/tailscaled --state=/run/secure-unlock-tailscale/tailscaled.state --statedir=/run/secure-unlock-tailscale --socket=/run/secure-unlock-tailscale/tailscaled.sock --tun=tailscale-unlock --port=0 --encrypt-state=false";
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };
    };
  };
}
