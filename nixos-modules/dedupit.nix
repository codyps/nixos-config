{ config, lib, self, ... }:
{
  imports = [
    self.inputs.dedupit.nixosModules.default
    ../modules/admin-commands.nix
  ];

  programs.adminCommands.commands = lib.mkIf config.services.dedupit.enable {
    dedupit-stats = [ "${config.services.dedupit.package}/bin/dedupit" "stats" ];
  };
}
