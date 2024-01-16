{
  description = "Home Manager configuration of cody";

  inputs = {
    # Specify the source of Home Manager and Nixpkgs.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
    targo = {
      url = "github:jmesmon/targo";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = { nixpkgs, home-manager, flake-utils, targo, ... }:
    let
      system = "x86_64-linux";
      pkgs = (import nixpkgs {
        inherit system;
        overlays = [
          (final: prev: {
            targo = targo.packages.${system}.default;
            nvim-send = (import ../nixpkgs/pkgs/nvim-send.nix {
              inherit (prev) rustPlatform fetchFromGitHub lib;
            });
          })
        ];
      });
    in
    {
      # chromeos
      homeConfigurations."cody@penguin" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;

        modules = [
          ({ ... }: {
            home.username = "cody";
            home.homeDirectory = "/home/cody";
          })
          ./home.nix
        ];
      };

      # vm on x-mbp
      homeConfigurations."x@adams" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;

        modules = [
          ({ ... }: {
            home.username = "x";
            home.homeDirectory = "/home/x";
          })
          ./home.nix
        ];
      };

    } // flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; }; in
      {
        formatter = pkgs.nixpkgs-fmt;
      }
    );
}
