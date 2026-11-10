{ lib, pkgs, ... }:
{
  nixpkgs.hostPlatform = "aarch64-darwin";
  # Match the build group created by the Lix macOS installer.
  ids.gids.nixbld = 350;

  networking.hostName = "kestrel";
  networking.computerName = "kestrel";
  networking.localHostName = "kestrel";

  system.primaryUser = "cody";
  users.users.cody = {
    name = "cody";
    home = "/Users/cody";
  };

  home-manager.users.cody.programs.git.signing = {
    format = lib.mkForce "ssh";
    key = lib.mkForce "~/.ssh/id_ed25519";
    signByDefault = lib.mkForce true;
  };

  nix.enable = true;
  nix.package = pkgs.lix;
  # /nix was installed on case-sensitive APFS; preserve original filenames.
  nix.settings.use-case-hack = false;
  nix.settings.auto-optimise-store = false;

  # Home Manager initializes completions after extending the user profile paths.
  programs.zsh.enableGlobalCompInit = false;
}
