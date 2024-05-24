{ config, pkgs, ... }:
let
  cache-home =
    if pkgs.stdenv.isDarwin then
      "Library/Caches"
    else
      ".cache"
  ;
in
{

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "23.05"; # Please read the comment before changing.

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = [
    # # Adds the 'hello' command to your environment. It prints a friendly
    # # "Hello, world!" when run.
    # pkgs.hello

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
    pkgs.atuin
    pkgs.cargo-generate
    pkgs.cargo-limit
    #pkgs.cargo-outdated
    pkgs.ccache
    pkgs.curl
    pkgs.exiftool
    pkgs.fd
    pkgs.fzf
    pkgs.git
    pkgs.git-crypt
    pkgs.gnupg
    pkgs.htop
    pkgs.ncdu
    pkgs.neovim
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

    pkgs.krew
    pkgs.kubectl
  ];

  programs.git = {
    enable = true;
    includes = [
      { path = "~/.config/git/general"; }
      { path = "~/.config/git/msmtp"; }
      { path = "~/.config/git/id"; }
      { path = "~/priv/gitconfig"; }
      {
        path = "~/.config/git/id.rivian";
        condition = "gitdir:~/rivian/";
      }
      {
        path = "~/.config/git/id.rivian";
        condition = "gitdir:/Volumes/dev/rivian/";
      }
    ];

    extraConfig = {
      core = {
        precomposeUnicode = true;
      };
      credential."https://dev.azure.com" = {
        useHttpPath = true;
      };
    };

    lfs.enable = true;
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;

    # # You can also set the file content immediately.
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
    "${cache-home}/nix/current-home-flake".source = ../.;
  };


  # You can also manage environment variables but you will have to manually
  # source
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/cody/etc/profile.d/hm-session-vars.sh
  #
  # if you don't want to manage your shell through Home Manager.
  home.sessionVariables = {
    # EDITOR = "emacs";
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  programs.atuin.enable = true;
}
