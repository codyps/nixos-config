{ config, pkgs, ... }:
{
  imports = [
    ./home-minimal.nix
  ];

  home.packages = [
    #pkgs.cargo-outdated
    #pkgs.ncdu
    pkgs.atuin
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
    pkgs.krew
    pkgs.kubectl
    pkgs.nodejs
    pkgs.openssh
    pkgs.rclone
    pkgs.ripgrep
    pkgs.rsync
    pkgs.rust-bindgen
    pkgs.rustup
    pkgs.sccache
    pkgs.socat
    pkgs.targo
    pkgs.tmux
    pkgs.tokei
    pkgs.universal-ctags
    pkgs.watch
    pkgs.xsv
    pkgs.yt-dlp

    (pkgs.wrapHelm pkgs.kubernetes-helm {
      plugins = with pkgs.kubernetes-helmPlugins; [
        helm-diff
      ];
    })
  ];
}
