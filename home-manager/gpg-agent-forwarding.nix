{ lib, pkgs, osConfig ? null, ... }:

let
  forwardingConfig = pkgs.writeText "ssh-gpg-agent-forwarding.conf"
    (import ../lib/gpg-agent-forwarding.nix { inherit lib pkgs; });
  installSshConfig = pkgs.writeShellScript "install-user-ssh-config" ''
    set -eu
    umask 077
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}

    install_config() {
      local source="$1" target="$2" directory temporary
      directory=$(dirname -- "$target")
      mkdir -p -- "$directory"
      temporary=$(mktemp "$directory/.ssh-config.XXXXXXXX")
      (
        trap 'rm -f -- "$temporary"' EXIT
        cat -- "$source" > "$temporary"
        mv -fT -- "$temporary" "$target"
      )
    }

    install_config ${../config/.ssh/config} "$HOME/.ssh/home-manager.conf"
    ${lib.optionalString (osConfig == null) ''
      install_config ${forwardingConfig} "$HOME/.ssh/config.d/gpg-agent-forwarding"
    ''}

    if [[ ! -e "$HOME/.ssh/config" && ! -L "$HOME/.ssh/config" ]]; then
      (
        set -o noclobber
        printf '%s\n' 'Include ~/.ssh/home-manager.conf' > "$HOME/.ssh/config"
      )
    fi
  '';
in
{
  # OpenSSH checks ownership of both the user config and its includes.
  # Install after Home Manager removes the links from the old generation.
  home.activation.installSshConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run ${installSshConfig}
  '';
}
