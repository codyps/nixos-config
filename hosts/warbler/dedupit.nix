{ ... }:
{
  imports = [ ../../nixos-modules/dedupit.nix ];
  services.dedupit.enable = true;
  services.dedupit.device = "/dev/mapper/cryptroot";
}
