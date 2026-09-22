{ pkgs, ... }:
{
  # Alternate environment: do not mount or migrate the host AI account's home.
  # /var/lib is already persisted on Warbler's encrypted /persist filesystem.
  containers.ai = {
    autoStart = true;
    ephemeral = false;
    privateNetwork = true;
    macvlans = [ "eno1" ];
    config = {
      imports = [ ./ai-container-guest.nix ];
      nixpkgs.pkgs = pkgs;
    };
  };
  systemd.services."container@ai".unitConfig.RequiresMountsFor = [ "/var/lib/nixos-containers" ];
}
