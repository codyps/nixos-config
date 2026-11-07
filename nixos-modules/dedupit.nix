{ config, lib, self, ... }:
{
  imports = [
    self.inputs.dedupit.nixosModules.default
    ../modules/admin-commands.nix
  ];

  programs.adminCommands.commands = lib.mkIf config.services.dedupit.enable {
    dedupit-compact = [ "${config.services.dedupit.package}/bin/dedupit" "compact" "--database" "/var/lib/dedupit/filesystem.sqlite" "--storage" config.services.dedupit.databaseStorage ];
    dedupit-stats = [ "${config.services.dedupit.package}/bin/dedupit" "stats" ];
  };
}
