{ ... }:
{
  imports = [ ../../nixos-modules/dedupit.nix ];
  services.dedupit.enable = true;
  services.dedupit.databaseStorage = "nocow";
  services.dedupit.device = "/dev/mapper/cryptroot";
}
