{ lib, pkgs, ... }:
let
  default-cache-subdirectory =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "Library/Caches"
    else
      ".cache";

  cargo-with-cached-target = pkgs.writeShellApplication {
    name = "cargo";
    runtimeInputs = with pkgs; [
      coreutils
      jq
    ];
    text = ''
      export CARGO_WRAPPER_REAL_CARGO=${lib.escapeShellArg "${pkgs.rustup}/bin/cargo"}
      export CARGO_WRAPPER_DEFAULT_CACHE_SUBDIRECTORY=${lib.escapeShellArg default-cache-subdirectory}
      ${builtins.readFile ../scripts/cargo-with-cached-target.sh}
    '';
  };
  cargo-gc = pkgs.writeShellApplication {
    name = "cargo-gc";
    text = ''
      exec ${pkgs.python3}/bin/python3 ${../scripts/cargo-gc.py} "$@"
    '';
  };
in
{
  imports = [
    ./home-minimal.nix
  ];

  home.packages = [
    #pkgs.cargo-outdated
    #pkgs.ncdu
    pkgs.nixd
    pkgs.atuin
    pkgs.bazelisk
    pkgs.cargo-generate
    pkgs.cargo-limit
    (lib.hiPrio cargo-with-cached-target)
    cargo-gc
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
    pkgs.sccache
    pkgs.socat
    #pkgs.targo
    pkgs.tmux
    pkgs.tokei
    pkgs.universal-ctags
    pkgs.watch
    pkgs.yt-dlp

  ];
}
