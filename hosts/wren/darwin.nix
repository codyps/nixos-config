{ lib, pkgs, ... }:
{
  imports = [ ../../nix-darwin/modules/remote-builder.nix ];

  # Intel Mac mini (Macmini8,1), six-core Core i7, 32 GiB RAM.
  nixpkgs.hostPlatform = "x86_64-darwin";
  # The Lix macOS installer creates this group with GID 350. The shared
  # stateVersion 4 would otherwise select nix-darwin's legacy GID 30000.
  ids.gids.nixbld = 350;

  networking.hostName = "wren";
  networking.computerName = "wren";
  networking.localHostName = "wren";

  # Keep the headless host available and recover when mains power returns.
  power.sleep.computer = "never";
  power.sleep.allowSleepByPowerButton = false;
  power.restartAfterPowerFailure = true;
  services.openssh.enable = true;
  services.tailscale.enable = true;
  launchd.daemons.tailscaled.serviceConfig.KeepAlive = true;
  services.remote-nix-builder = {
    enable = true;
    authorizedKeys = import ../../modules/builder-ssh-keys.nix;
  };

  system.primaryUser = "cody";
  users.users.cody = {
    name = "cody";
    home = "/Users/cody";
  };

  nix.enable = true;
  nix.package = pkgs.lix;
  nix.settings.use-case-hack = false;
  nix.settings.accept-flake-config = true;
  # Leave CPU and memory headroom for one future Actions VM.
  nix.settings.max-jobs = lib.mkForce 2;
  nix.settings.cores = 3;
  nix.settings.sandbox = true;
  # Avoid synchronous hard-link creation on APFS during builds.
  nix.settings.auto-optimise-store = false;

  # Bound store growth while retaining a month of rollback generations.
  nix.gc = {
    automatic = true;
    interval = [{ Weekday = 7; Hour = 3; Minute = 15; }];
    options = "--delete-older-than 30d";
  };

  # Home Manager initializes completions after adding the user profile to fpath.
  programs.zsh.enableGlobalCompInit = false;

  # Unattended commits must not wait for an interactive GPG unlock.
  home-manager.users.cody.programs.git.signing.signByDefault = lib.mkForce false;
}
