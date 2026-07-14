{ config, lib, pkgs, ... }:

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

  programs.zsh = {
    enable = true;
    history = {
      extended = true;
      save = 10000;
      size = 20000;
      share = false;
    };
    initContent = (builtins.readFile ../config/.zshrc);

    # cursor only invokes `~/.zshenv`, so we put things that need to be in the environment there, and things that should only be in interactive shells in `~/.zshrc`
    envExtra =
      if config.programs.direnv.enable then
        ''
          eval "$(${pkgs.direnv}/bin/direnv hook zsh)"
        ''
      else
        "";
  };

  programs.bash = {
    enable = true;

    historyFileSize = -1;
    historySize = -1;
    historyFile = "\${HOME}/.bash_history_eternal";

    initExtra = (builtins.readFile ../config/.bashrc);

    # goes in `~/.profile`, `~/.bash_profile` is empty
    profileExtra = (builtins.readFile ../config/.profile);
  };

  home.packages = [
    pkgs.gnupg
    pkgs.htop
    pkgs.ripgrep
    pkgs.rsync
    pkgs.socat
    pkgs.tmux
  ];

  programs.git = {
    enable = true;
    includes = [
      { path = "~/priv/gitconfig"; }
      {
        path = "work";
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

    settings = {
      core = {
        fscache = true;
        preloadindex = true;
        precomposeUnicode = true;
      };
      user = {
        name = "Cody P Schafer";
        email = "dev@codyps.com";
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
      #credential = {
      #  #helper = "!${pkgs.pass-git-helper}/bin/pass-git-helper $0";
      #  useHttpPath = true;
      #};
      #credential."https://dev.azure.com" = {
      #  useHttpPath = true;
      #};

      url."git@gitlab.com:".insteadOf = "https://gitlab.com/";

      sendemail = {
        confirm = "auto";
        #smtpserver = "${pkgs.msmtp}/bin/msmtp";
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
    withPython3 = true;
    withRuby = false;
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  programs.nix-index.enable = true;

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
    ".ssh/config".source = ../config/.ssh/config;
  };
}
