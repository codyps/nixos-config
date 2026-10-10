{ config, pkgs, ... }:
{
  imports = [ ../../modules/admin-commands.nix ];

  # Make interactive sbctl use the same existing keys as Lanzaboote.
  environment.etc."sbctl/sbctl.conf".text = ''
    keydir: ${config.boot.lanzaboote.pkiBundle}/keys
    guid: ${config.boot.lanzaboote.pkiBundle}/GUID
  '';
  programs.adminCommands.commands = {
    backup-secure-boot = [
      "${pkgs.callPackage ../warbler/secure-boot-backup.nix { hostName = config.networking.hostName; }}/bin/warbler-secure-boot-backup"
    ];
    # sbctl requires firmware Setup Mode. Back up firmware databases before
    # clearing keys, then enable Secure Boot in firmware after enrollment.
    setup-secure-boot = [ "${pkgs.sbctl}/bin/sbctl" "enroll-keys" "--microsoft" ];
  };
}
