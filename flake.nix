{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";
    nixos-wsl.inputs.flake-utils.follows = "flake-utils";
    nixos-vscode-server.url = "github:nix-community/nixos-vscode-server";
    nixos-vscode-server.inputs.nixpkgs.follows = "nixpkgs";
    nixos-vscode-server.inputs.flake-utils.follows = "flake-utils";
    flake-utils.url = "github:numtide/flake-utils";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    targo.url = "github:codyps/targo";
    targo.inputs.nixpkgs.follows = "nixpkgs";
    targo.inputs.flake-utils.follows = "flake-utils";
    impermanence.url = "github:nix-community/impermanence";
    ethereum-nix = {
      url = "github:nix-community/ethereum.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = { self, nixpkgs, flake-utils, targo, nix-darwin, home-manager, nixos-wsl, nixos-vscode-server, impermanence, ethereum-nix }:
    let
      overlays = [
        (final: prev: {
          targo = targo.packages.${prev.system}.default;

          # something is using the old name, hack around it.
          utillinux = prev.util-linux;
        })
        (import ./nixpkgs/overlays/overlay.nix)
      ];

      getName = pkg: pkg.pname or (builtins.parseDrvName pkg.name).name;
      nixpkgsConfig = {
        config.allowUnfreePredicate = pkg: builtins.elem (getName pkg) [
          "vscode"
          "copilot.vim"
        ];
        inherit overlays;
      };
    in
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            inherit overlays;
          };
        in
        {
          formatter = pkgs.nixpkgs-fmt;
        }
      ) //
    (
      let
        nixosSystem = nixpkgs.lib.nixosSystem;
      in
      {
        nixosConfigurations = {
          # u3 macbook vmware vm
          mifflin = nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit home-manager self; };
            modules = [
              ./nixos/mifflin/configuration.nix
              ./nixos/common.nix
              home-manager.nixosModules.home-manager
              {
                nixpkgs = nixpkgsConfig;
                home-manager.useGlobalPkgs = true;
                home-manager.useUserPackages = true;
                home-manager.users.cody.imports = [
                  ./home-manager/home.nix
                ];
              }
            ];
          };

          # storage vps
          finch = nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit self; };
            modules = [
              ./nixos/finch/configuration.nix
              ./nixos/common.nix
              impermanence.nixosModules.impermanence
              home-manager.nixosModules.home-manager
              {
                nixpkgs = nixpkgsConfig;
                home-manager.useGlobalPkgs = true;
                home-manager.useUserPackages = true;
                home-manager.users.cody.imports = [
                  ./home-manager/home-minimal.nix
                ];
              }
            ];
          };

          # router
          ward = nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit home-manager self; };
            modules = [
              ethereum-nix.nixosModules.default
              ./nixos/ward/configuration.nix
              ./nixos/common.nix
              impermanence.nixosModules.impermanence
              home-manager.nixosModules.home-manager
              {
                nixpkgs = nixpkgsConfig;
                home-manager.useGlobalPkgs = true;
                home-manager.useUserPackages = true;
                home-manager.users.cody.imports = [
                  ./home-manager/home.nix
                ];
              }
            ];
          };

          # framework wsl
          findley = nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit home-manager nixos-wsl nixos-vscode-server self; };
            modules = [
              ./nixos/findley/configuration.nix
              ./nixos/common.nix
              home-manager.nixosModules.home-manager
              {
                nixpkgs = nixpkgsConfig;
                home-manager.useGlobalPkgs = true;
                home-manager.useUserPackages = true;
                home-manager.users.nixos.imports = [
                  ./home-manager/home.nix
                ];
              }
            ];
          };

          # old sony vaio	
          constance = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit home-manager; };
            modules = [
              ./nixos/constance/configuration.nix
            ];
          };

          # x220
          forbes = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit home-manager; };
            modules = [
              ./nixos/forbes/configuration.nix
            ];
          };

          # work vmware vm
          trunix = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              ./nixos/trunix/configuration.nix
            ];
          };

          # work utm vm
          maclay = nixpkgs.lib.nixosSystem {
            system = "aarch64-linux";
            specialArgs = { inherit home-manager self; };
            modules = [
              ./nixos/common.nix
              ./nixos/maclay/configuration.nix
              home-manager.nixosModules.home-manager
              {
                nixpkgs = nixpkgsConfig;
                home-manager.useGlobalPkgs = true;
                home-manager.useUserPackages = true;
                home-manager.users.cody.imports = [
                  ./home-manager/home.nix
                ];
              }
            ];
          };

          # x-mbp vmware vm
          adams = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";

            modules = [
              ./nixos/adams/configuration.nix
            ];
          };

          calvin = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";

            modules = [
              ./nixos/calvin/configuration.nix
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
              nixpkgs.hostPlatform = "x86_64-darwin";
            })
            ./nix-darwin/configuration.nix
            home-manager.darwinModules.home-manager
            {
              nixpkgs = nixpkgsConfig;
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.x.imports = [
                ./nix-darwin/home.nix
                ./home-manager/home.nix
              ];
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
              nixpkgs.hostPlatform = "x86_64-darwin";
              nix.settings.use-case-hack = false;
              nix.extraOptions = ''
                #upgrade-nix-store-path-url = "https://install.determinate.systems/nix-upgrade/stable/universal";
              '';

              # FIXME: included because we don't include `nixos/common.nix` here.
              p.nix.buildMachines.ward.enable = true;
              p.nix.buildMachines.ward.sshKey = "/etc/nix/keys/nix_ed25519";
            })
            ./nix-darwin/configuration.nix
            ./modules/build-machines.nix
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

        darwinConfigurations."RVW-LYY7YT7329M" = nix-darwin.lib.darwinSystem {
          specialArgs = { inherit self; };
          modules = [
            ({ ... }: {
              users.users.codyschafer = {
                name = "codyschafer";
                home = "/Users/codyschafer";
              };
              nixpkgs.hostPlatform = "aarch64-darwin";
              nix.settings.use-case-hack = false;
              nix.extraOptions = ''
                bash-prompt-prefix = (nix:$name)\040
                #upgrade-nix-store-path-url = "https://install.determinate.systems/nix-upgrade/stable/universal";
              '';
            })
            ./nix-darwin/configuration.nix
            ({ ... }: {
              nix.buildMachines = [{
                sshUser = "nix-ssh";
                hostName = "maclay.local";
                systems = [ "aarch64-linux" "x86_64-linux" ];
                maxJobs = 4;
                speedFactor = 20;
                sshKey = "/etc/nix/keys/maclay_ed25519";
                publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSVA5NVdyeTBGOUFjbWp2cldZOWVJZnQ3TGdPWDF2NU9HdnN1cjBIb29oWWIgcm9vdEBuaXhvcwo=";
                supportedFeatures = [ "benchmark" "big-parallel" "kvm" ];
                protocol = "ssh-ng";
              }];
            })
            home-manager.darwinModules.home-manager
            {
              nixpkgs = nixpkgsConfig;
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.codyschafer = {
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
            inherit overlays;
            inherit (nixpkgsConfig) config;
          });
        in
        {

          # chromeos
          homeConfigurations."cody@peyton" = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;

            modules = [
              ({ ... }: {
                home.username = "cody";
                home.homeDirectory = "/home/cody";
              })
              ./home-manager/home.nix
            ];
          };

          # arnold
          homeConfigurations."y@arnold" = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;

            modules = [
              ({ ... }: {
                home.username = "y";
                home.homeDirectory = "/home/y";
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

          homeConfigurations."cody@constance" = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;

            modules = [
              ({ ... }: {
                home.username = "cody";
                home.homeDirectory = "/home/cody";
              })
              ./home-manager/home.nix
            ];
          };
        }
      )
    );
}
