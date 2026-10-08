{ pkgs, ... }:
{
  imports = [
    ../modules/admin-commands.nix
    ./home-minimal.nix
    ./mbx.nix
  ];

  config.programs.mbx.enable = true;

  config.home.packages = [
    #pkgs.cargo-outdated
    #pkgs.ncdu
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

  ];
}
