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
  ];

  programs.git = {
    userName = "Cody P Schafer";
    userEmail = "dev@codyps.com";

    enable = true;
    includes = [
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

    ignores = [
      ".*.swp"
      ".*.swo"
      "*~"
      ".DS_Store"
      ".direnv"
      ".vim/"
    ];

    signing = {
      signByDefault = true;
      key = "881CEAC38C98647F6F660956794D748B8B8BF912";
    };

    extraConfig = {
      core = {
        fscache = true;
        preloadindex = true;
        precomposeUnicode = true;
      };
      credential."https://dev.azure.com" = {
        useHttpPath = true;
      };
      pull = {
        ff = "only";
      };
      push = {
        default = "current";
      };
      log = {
        date = "iso";
      };
      color = {
        ui = "auto";
      };
      alias = {
        post = "!sh -c '${pkgs.git}/bin/git format-patch --stdout $1 | ${pkgs.ix}/bin/ix' -";
        ci = "commit -v";
        st = "status";
        co = "checkout";
        b = "branch -v";
        dc = "describe --contains";
        fp = "format-patch -k -M -N";
        tree = "log --graph --decorate --pretty=oneline --abbrev-commit";
        sm = "submodule";
        submod = "submodule";
      };
      am = {
        keepcr = "no";
      };
      rerere = {
        enabled = true;
      };
      advice = {
        detachedHead = false;
      };
      color.diff = {
        whitespace = "red reverse";
      };
      gc = {
        auto = "256";
      };
      credential = {
        helper = "!${pkgs.pass-git-helper}/bin/pass-git-helper $0";
        useHttpPath = true;
      };

      url."ssh://git@gitlab.com/".insteadOf = "https://gitlab.com/";

      sendemail = {
        confirm = "auto";
        smtpserver = "${pkgs.msmtp}/bin/msmtp";
        #smtpserveroption = "--read-envelope-from";
        chainreplyto = false;
        aliasfiletype = "mutt";
        aliasesfile = "~/.muttaliases";
        envelopesender = "auto";
      };
    };

    lfs.enable = true;
  };

  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    plugins = with pkgs.vimPlugins; [
      #cargo-limit
      #jenkinsfile-vim-syntax
      #v-vim
      coc-go
      coc-nvim
      coc-rust-analyzer
      coc-sh
      coc-toml
      coc-yaml
      copilot-vim
      ctrlp-vim
      fzf-vim
      fzfWrapper
      kotlin-vim
      rust-vim
      securemodelines
      vim-airline
      vim-lastplace
      vim-nix
      vim-rooter
      vim-sneak
      vim-terraform
      vim-toml
      zig-vim
    ];

    extraConfig = ''
      set runtimepath^=~/.config/nvim/raw runtimepath+=~/.config/nvim/raw/after
      source ~/.config/nvim/raw/init.vim
    '';
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  programs.nix-index.enable = true;

  programs.fzf = {
    enable = true;
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.atuin = {
    enable = true;
    flags = [ "--disable-up-arrow" ];
  };

  home.file = {
    "${cache-home}/nix/current-home-flake".source = ../.;
    ".tmux.conf".source = ../config/.tmux.conf;
  };

  xdg.configFile."nvim/raw".source = ./nvim;

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
}
