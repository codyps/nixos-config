{ config, lib, ... }:
{
  imports = [ ../../modules/gpg-agent-forwarding.nix ];

  config = lib.mkIf (config.system.primaryUser != "codyschafer") {
    services.openssh.extraConfig = ''
      StreamLocalBindUnlink yes
    '';
  };
}
