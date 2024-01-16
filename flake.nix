{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    targo.url = "github:jmesmon/targo";
    targo.inputs.nixpkgs.follows = "nixpkgs";
    targo.inputs.flake-utils.follows = "flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, targo, nix-darwin, home-manager }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
          overlays = self.overlays;

        in
        {
          formatter = pkgs.nixpkgs-fmt;
          overlays = [
            (final: prev: {
              targo = targo.packages.${prev.system}.default;
              nvim-send = (import ../nixpkgs/pkgs/nvim-send.nix {
                inherit (prev) rustPlatform fetchFromGitHub lib;
              });
            })
          ];
        }

      ) //
    (
      let
        getName = pkg: pkg.pname or (builtins.parseDrvName pkg.name).name;
        nixpkgsConfig = {
          config.allowUnfreePredicate = pkg: builtins.elem (getName pkg) [
            "vscode"
          ];
        };
      in
      {
        nixosConfigurations = {
          # work vmware vm
          trunix = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              (import ./trunix/configuration.nix)
            ];
          };

          # x-mbp vmware vm
          adams = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";

            modules = [
              (import ./adams/configuration.nix)
            ];
          };

          calvin = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";

            modules = [
              (import ./calvin/configuration.nix)
            ];
          };
        };

        # Build darwin flake using:
        # $ darwin-rebuild build --flake .#x-mbp
        darwinConfigurations."x-mbp" = nix-darwin.lib.darwinSystem {
          specialArgs = { inherit self; };
          modules = [
            ({ ... }: {
              users.users.x = {
                name = "x";
                home = "/Users/x";
              };
            })
            ./nix-darwin/configuration.nix
            ./nix-darwin/linuxBuilder.nix
            home-manager.darwinModules.home-manager
            {
              nixpkgs = nixpkgsConfig;
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.x = {
                imports = [
                  ./nix-darwin/home.nix
                  ./home-manager/home.nix
                ];
              };
            }
          ];
        };

        darwinConfigurations."u3" = nix-darwin.lib.darwinSystem {
          specialArgs = { inherit self; };
          modules = [
            ({ ... }: {
              users.users.cody = {
                name = "cody";
                home = "/Users/cody";
              };
            })
            ./nix-darwin/configuration.nix
            ./nix-darwin/linuxBuilder.nix
            home-manager.darwinModules.home-manager
            {
              nixpkgs = nixpkgsConfig;
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.cody = {
                imports = [
                  ./nix-darwin/home.nix
                  ./home-manager/home.nix
                ];
              };
            }
          ];
        };
      } // (
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
              ./home-manager/home.nix
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
              ./home-manager/home.nix
            ];
          };
        }
      )
    );
}
