{ config, pkgs, ... }:
let
  npmGlobalPrefix = "${config.home.homeDirectory}/.npm-global";
in
{
  imports = [
    ../modules/admin-commands.nix
    ./home-minimal.nix
    ./mbx.nix
  ];

  config.programs.mbx.enable = true;

  # Nix's npm defaults its global prefix to the read-only store, so
  # `npm install -g` (and self-updaters that call it) fail with EACCES.
  # Use a writable per-user prefix whose bin directory precedes Homebrew.
  config.home.sessionVariables.NPM_CONFIG_PREFIX = npmGlobalPrefix;
  config.home.sessionPath = [ "${npmGlobalPrefix}/bin" ];

  config.home.packages = [
    #pkgs.cargo-outdated
    pkgs.nixd
    pkgs.bazelisk
    pkgs.cargo-generate
    pkgs.cargo-limit
    pkgs.ccache
    pkgs.curl
    pkgs.exiftool
    pkgs.fd
    pkgs.fzf
    pkgs.git
    pkgs.git-crypt
    pkgs.gnupg
    pkgs.htop
    pkgs.nodejs
    pkgs.openssh
    pkgs.rclone
    pkgs.ripgrep
    pkgs.rsync
    pkgs.rust-bindgen
    pkgs.rustup
    pkgs.socat
    #pkgs.targo
    pkgs.tmux
    pkgs.tokei
    pkgs.universal-ctags
    pkgs.watch
    pkgs.yt-dlp
    pkgs.opencode

  ];
}
