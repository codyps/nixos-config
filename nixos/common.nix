{ ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;

    # TODO: pinentry? need to know which one is appropriate for system.
  };
  programs.zsh.enable = true;
}
