{ self, pkgs, ... }:

let
  processor = pkgs.stdenv.hostPlatform.uname.processor;
  nonnative_processor = if processor == "x86_64" then "aarch64" else "x86_64";
  nonnative_linux = "${nonnative_processor}-linux";
in
{
  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = with pkgs; [
    atuin
    curl
    fd
    git
    #ncdu
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
  ];

  # Auto upgrade nix package and the daemon service.
  # nix.package = pkgs.nix;

  nix.enable = true;
  nix.settings = {
    experimental-features = "nix-command flakes";
    max-jobs = "auto";
    extra-nix-path = "nixpkgs=flake:nixpkgs";
    trusted-users = [ "root" "@admin" ];
  };

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
    #systems =
    #  if processor == "aarch64" then
    #    [ "${processor}-linux" ]
    #  else
    #    [ "${processor}-linux" "${nonnative_linux}" ]
    #;
    speedFactor = 10;
    maxJobs = 4;
    #config = ({ ... }:
    #  {
    #    boot.binfmt.emulatedSystems = [ nonnative_linux ];
    #    virtualisation.cores = if processor == "aarch64" then 16 else 8;
    #  }
    #);
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
