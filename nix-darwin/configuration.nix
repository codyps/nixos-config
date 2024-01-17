{ self, pkgs, ... }: {
  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = with pkgs; [
    atuin
    curl
    fd
    git
    ncdu
    neovim
    nix-direnv
    nodejs
    ripgrep
    rsync
    tmux
    fzf
    gnupg
    ccache
    cargo-generate
    tokei
    rust-bindgen
    xsv
  ];

  # Auto upgrade nix package and the daemon service.
  services.nix-daemon.enable = true;
  # nix.package = pkgs.nix;


  # Necessary for using flakes on this system.
  nix.settings.experimental-features = "nix-command flakes";

  nix.settings.trusted-users = [ "root" "@admin" ];

  nix.buildMachines = [{
    hostName = "arnold";
    system = "x86_64-linux";
    maxJobs = 4;
    supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
    protocol = "ssh-ng";
  }];

  environment.etc."nix/ssh_config.d/linux-builder".text = ''
    Host arnold
      User nix
      HostName 100.96.147.23
      IdentityFile /etc/nix/keys/arnold_ed25519
      UserKnownHostsFile /etc/nix/ssh_known_hosts.d/arnold
  '';

  environment.etc."nix/ssh_known_hosts.d/arnold".text = ''
    100.96.147.23 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFLLtofc9hAToGZfafrlv8/4tE5W0IARQ8nHs8DpBMSk
  '';

  ##ssh-ng://nix@100.96.147.23?ssh-key=/etc/nix/arnold_ed25519
  nix.settings.substituters = [ "https://nix-community.cachix.org" ];
  nix.settings.trusted-public-keys = [ "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=" "builder-name:V3galmyKya9h+w11jUnPeq7bZ7h+G8mxl2F6rR0avPQ=" ];
  nix.extraOptions = ''
    builders-use-substitutes = true
    builders = @/etc/nix/machines
  '';

  # Create /etc/zshrc that loads the nix-darwin environment.
  programs.zsh.enable = true; # default shell on catalina

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;

  # Set Git commit hash for darwin-version.
  system.configurationRevision = self.rev or self.dirtyRev or null;

  environment.etc."nix/source-flake".source = ./.;
}
