{ config, pkgs, ... }:

{
  imports = [
    ./home-no-shell.nix
  ];

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
    enable = true;

    historyFileSize = -1;
    historySize = -1;
    historyFile = "\${HOME}/.bash_history_eternal";

    initExtra = (builtins.readFile ./bashrc);

    # goes in `~/.profile`, `~/.bash_profile` is empty
    profileExtra = (builtins.readFile ./profile.sh);
  };
}
