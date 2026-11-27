{ lib, pkgs, osConfig ? null, ... }:
{
  # System modules supply the same rules for integrated NixOS/Darwin homes.
  home.file.".ssh/config.d/gpg-agent-forwarding" = lib.mkIf (osConfig == null) {
    text = import ../lib/gpg-agent-forwarding.nix { inherit lib pkgs; };
  };

  home.file.".ssh/home-manager.conf".source = ../config/.ssh/config;

  # OpenSSH checks ownership of the default user config. A regular file
  # owned by the user can include the Home Manager symlink.
  # Run after Home Manager removes the old .ssh/config link.
  home.activation.installSshConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if [[ ! -e "$HOME/.ssh/config" && ! -L "$HOME/.ssh/config" ]]; then
      run ${pkgs.bash}/bin/bash -c '
        umask 077
        set -o noclobber
        printf "%s\n" "Include ~/.ssh/home-manager.conf" > "$1"
      ' bash "$HOME/.ssh/config"
    fi
  '';
}
