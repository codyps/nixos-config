{ config, lib, ... }:
{
  imports = [ ../modules/gpg-agent-forwarding.nix ];

  config = lib.mkIf (!builtins.elem config.networking.hostName [ "maclay" "trunix" ]) {
    programs.gnupg.agent.enable = lib.mkDefault true;
    programs.gnupg.agent.enableExtraSocket = true;
    services.openssh.settings.StreamLocalBindUnlink = "yes";
  };
}
