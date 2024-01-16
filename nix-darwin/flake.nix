{
  description = "Cody's NixOS Darwin configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    targo.url = "github:jmesmon/targo";
    targo.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nix-darwin, nixpkgs, home-manager, targo }:
    let
      getName = pkg: pkg.pname or (builtins.parseDrvName pkg.name).name;
      nixpkgsConfig = {
        #config.allowUnfree = true;

        config.allowUnfreePredicate = pkg: builtins.elem (getName pkg) [
          "vscode"
        ];

        overlays = self.overlays;
      };
    in
    {
      overlays = [
        (final: prev: {
          targo = targo.packages.${prev.system}.default;
          nvim-send = (import ../nixpkgs/pkgs/nvim-send.nix {
            inherit (prev) rustPlatform fetchFromGitHub lib;
          });
        })
      ];

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
          ./configuration.nix
          ./linuxBuilder.nix
          home-manager.darwinModules.home-manager
          {
            nixpkgs = nixpkgsConfig;
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.x = {
              imports = [
                ./home.nix
                ../home-manager/home.nix
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
          ./configuration.nix
          ./linuxBuilder.nix
          home-manager.darwinModules.home-manager
          {
            nixpkgs = nixpkgsConfig;
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.cody = {
              imports = [
                ./home.nix
                ../home-manager/home.nix
              ];
            };
          }
        ];
      };
    };
}
