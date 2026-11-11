{ config, lib, pkgs, self, ... }:
{
  imports = [
    self.inputs.dedupit.nixosModules.default
    ../modules/admin-commands.nix
  ];

  # The upstream module builds its package with an internal callPackage, which
  # bypasses the overlay's system-library fix-up; use the overlaid package.
  services.dedupit.package = lib.mkDefault pkgs.dedupit;

  programs.adminCommands.commands = lib.mkIf config.services.dedupit.enable {
    dedupit-compact = [ "${config.services.dedupit.package}/bin/dedupit" "compact" "--database" "/var/lib/dedupit/filesystem.sqlite" "--storage" config.services.dedupit.databaseStorage ];
    dedupit-stats = [ "${config.services.dedupit.package}/bin/dedupit" "stats" ];
  };
}
