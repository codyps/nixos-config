{ config, lib, pkgs, ... }:
{
  imports = [ ../modules/admin-commands.nix ];
  options.programs.actions-vm-image.enable = lib.mkEnableOption "Actions VM image preparation tools";
  config = lib.mkIf config.programs.actions-vm-image.enable {
    assertions = [{
      assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
      message = "actions-vm-image requires x86_64 Linux/KVM.";
    }];
    programs.adminCommands.commands.actions-windows-image = [
      "${pkgs.callPackage ../nixpkgs/actions-windows-image.nix { }}/bin/actions-windows-image"
    ];
    programs.adminCommands.commands.actions-vm-image = [
      "${pkgs.callPackage ../nixpkgs/actions-vm-image.nix { }}/bin/actions-vm-image"
    ];
  };
}
