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

  nix.settings = {
    experimental-features = "nix-command flakes repl-flake";
    max-jobs = "auto";
    extra-nix-path = "nixpkgs=flake:nixpkgs";
    trusted-users = [ "root" "@admin" ];
  };

  nix.buildMachines = [{
    sshUser = "nix";
    hostName = "arnold-local";
    systems = [ "x86_64-linux" "aarch64-linux" ];
    maxJobs = 4;
    sshKey = "/etc/nix/keys/arnold_ed25519";
    #publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUZMTHRvZmM5aEFUb0daZmFmcmx2OC80dEU1VzBJQVJROG5IczhEcEJNU2sgcm9vdEBhcm5vbGQK";
    supportedFeatures = [ "benchmark" "big-parallel" "kvm" ];
    protocol = "ssh-ng";
  }];

  environment.etc."ssh/ssh_config.d/100-arnold-local.conf".text = ''
    Host arnold-local
      HostName 192.168.6.10
      HostKeyAlias arnold
  '';

  nix.settings.substituters = [ "https://nix-community.cachix.org" ];
  nix.settings.trusted-public-keys = [ "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=" "builder-name:V3galmyKya9h+w11jUnPeq7bZ7h+G8mxl2F6rR0avPQ=" ];
  nix.extraOptions = ''
    builders-use-substitutes = true
    builders = @/etc/nix/machines
  '';

  # FIXME: customize so this does the right thing for x86_64 and aarch64
  nix.linux-builder = {
    enable = true;
    # FIXME: qemu-x86_64 SIGSEV, so removed extra system
    # > qemu-x86_64: QEMU internal SIGSEGV {code=MAPERR, addr=0x20}
    systems = if pkgs.system == "aarch64-darwin" then
      [ "aarch64-linux" ]
    else
      [ "x86_64-linux" "aarch64-linux"]
    ;
    speedFactor = 10;
    maxJobs = 4;
    config = ({ ... }:
      {
        boot.binfmt.emulatedSystems = if pkgs.system == "aarch64-darwin" then [ "x86_64-linux"] else [ "aarch64-linux" ];
        virtualisation.cores = if pkgs.system == "aarch64-darwin" then 16 else 8;
      }
    );
  };

  # Create /etc/zshrc that loads the nix-darwin environment.
  programs.zsh.enable = true; # default shell on catalina

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;

  # Set Git commit hash for darwin-version.
  system.configurationRevision = self.rev or self.dirtyRev or null;

  environment.etc."nix/source-flake".source = ../.;
}
