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
    pkgs.bazelisk

    pkgs.krew
    pkgs.kubectl
  ];

  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    plugins = with pkgs.vimPlugins; [
      ctrlp-vim
      securemodelines
      vim-sneak
      vim-lastplace
      vim-rooter
      fzf-vim
      fzfWrapper
      coc-rust-analyzer
      coc-go
      coc-toml
      coc-yaml
      coc-sh
      coc-nvim
      rust-vim
      vim-toml
      vim-airline
      #v-vim
      zig-vim
      vim-terraform
      vim-nix
      #cargo-limit
      copilot-vim
      kotlin-vim
      #jenkinsfile-vim-syntax
    ];

    extraConfig = ''
      set runtimepath^=~/.config/nvim/raw runtimepath+=~/.config/nvim/raw/after
      source ~/.config/nvim/raw/init.vim
    '';
  };

  xdg.configFile."nvim/raw".source = ./nvim;

  programs.zsh = {
    enable = true;
    history = {
      extended = true;
      save = 10000;
      size = 20000;
      share = false;
    };
    initExtra = (builtins.readFile ./zshrc);
  };

  programs.bash = {
    historyFileSize = -1;
    historySize = -1;
    historyFile = "\${HOME}/.bash_history_eternal";

    enable = true;
    initExtra = (builtins.readFile ./bashrc);

    # goes in `~/.profile`, `~/.bash_profile` is empty
    profileExtra = (builtins.readFile ./profile.sh);
  };

  programs.nix-index.enable = true;
  programs.fzf = {
    enable = true;
  };

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
      # TODO: use absolute path
      credential = {
        helper = "!${pkgs.pass-git-helper}/bin/pass-git-helper $0";
        useHttpPath = true;
      };
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

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.atuin = {
    enable = true;
    flags = [ "--disable-up-arrow" ];
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
}
