{ pkgs, ... }:
{
  # Intel Mac mini (Macmini8,1), six-core Core i7, 32 GiB RAM.
  nixpkgs.hostPlatform = "x86_64-darwin";

  networking.hostName = "wren";
  networking.computerName = "wren";
  networking.localHostName = "wren";

  system.primaryUser = "cody";
  users.users.cody = {
    name = "cody";
    home = "/Users/cody";
  };

  nix.enable = true;
  nix.package = pkgs.lix;
  nix.settings.use-case-hack = false;
  nix.settings.accept-flake-config = true;
  # Avoid synchronous hard-link creation on APFS during builds.
  nix.settings.auto-optimise-store = false;

  # Home Manager initializes completions after adding the user profile to fpath.
  programs.zsh.enableGlobalCompInit = false;
}
