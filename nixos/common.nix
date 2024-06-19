{ pkgs, ... }:
{
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      trusted-users = [ "nix-ssh" "@wheel" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
    #buildMachines = [
    #];
    #distributedBuilds = true;
    sshServe = {
      enable = true;
      write = true;
      protocol = "ssh-ng";
    };
  };

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;

    # TODO: pinentry? need to know which one is appropriate for system.
  };
  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;
}
