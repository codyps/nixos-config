{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    atuin.url = "github:codyps/atuin/ctrl-r-memory";
    atuin.inputs.nixpkgs.follows = "nixpkgs";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    clipway.url = "github:krisztianfekete/clipway";
    clipway.inputs.nixpkgs.follows = "nixpkgs";

    # Nixpkgs 26.05 is the final release with an x86_64-darwin stdenv.
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    nix-darwin-26-05.url = "github:LnL7/nix-darwin/nix-darwin-26.05";
    nix-darwin-26-05.inputs.nixpkgs.follows = "nixpkgs-darwin";
    home-manager-26-05.url = "github:nix-community/home-manager/release-26.05";
    home-manager-26-05.inputs.nixpkgs.follows = "nixpkgs-darwin";

    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";
    nixos-vscode-server.url = "github:nix-community/nixos-vscode-server";
    flake-utils.url = "github:numtide/flake-utils";
    disko.url = "github:codyps/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    #targo.url = "github:codyps/targo";
    #targo.inputs.nixpkgs.follows = "nixpkgs";
    #targo.inputs.flake-utils.follows = "flake-utils";
    impermanence.url = "github:nix-community/impermanence";
    impermanence.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    #thereum-nix = {
    #  url = "github:codyps/ethereum.nix";
    #  inputs.nixpkgs.follows = "nixpkgs";
    #  inputs.flake-utils.follows = "flake-utils";
    #};
  };

  # Flake metadata must be literal; modules/nix-cache.nix reuses these values.
  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://codyps.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "codyps.cachix.org-1:T2SgQFUIPVsszIqt74ku8XhkfVDVm3sVzn4qOfUoEFY="
    ];
  };

  outputs = { self, atuin, nixpkgs, nixpkgs-darwin, flake-utils, nix-darwin, nix-darwin-26-05, home-manager, home-manager-26-05, nixos-wsl, nixos-vscode-server, impermanence, sops-nix, disko, clipway }:
    let
      withCache = constructor: args: constructor (args // {
        modules = [ ./modules/nix-cache.nix ] ++ args.modules;
      });
      mkOverlays = nixpkgsSource: [
        (final: prev:
          let
            # Use each host's package set, including the pinned Intel Darwin
            # stdenv, with the Rust version required by the Atuin fork.
            atuinToolchain = (prev.callPackage atuin.inputs.fenix { }).fromToolchainFile {
              file = atuin + "/rust-toolchain.toml";
              sha256 = "sha256-P30Tm3O7vQAE725YtDCDHGjNrSsfZO4us11UwJGZSJo=";
            };
            caddy = prev.callPackage (nixpkgsSource + "/pkgs/by-name/ca/caddy/package.nix") {
              inherit caddy;
            };
          in
          {
            inherit caddy;
            atuin = prev.callPackage (atuin + "/atuin.nix") {
              rustPlatform = prev.makeRustPlatform {
                cargo = atuinToolchain;
                rustc = atuinToolchain;
              };
            };
            caddyFull = caddy.withPlugins {
              plugins = [
                "github.com/caddy-dns/cloudflare@v0.2.2-0.20250506153119-35fb8474f57d"
                "github.com/caddyserver/cache-handler@v0.14.0"
                "github.com/darkweak/storages/badger/caddy@v0.0.10"
                "github.com/WeidiDeng/caddy-cloudflare-ip@v0.0.0-20231130002422-f53b62aa13cb"
              ];
              # The pinned Darwin package set has a separate Caddy source bundle.
              hash = if nixpkgsSource.outPath == nixpkgs.outPath
                then (builtins.fromJSON (builtins.readFile ./nixpkgs/caddy-hashes.json)).nixpkgs
                else (builtins.fromJSON (builtins.readFile ./nixpkgs/caddy-hashes.json)).nixpkgs-darwin;
            };

            audiobookshelf-headless =
              let
                package = nixpkgsSource + "/pkgs/by-name/au/audiobookshelf/package.nix";
                args = builtins.functionArgs (import package);
              in prev.callPackage package (
                if args ? ffmpeg_8-full
                then { ffmpeg_8-full = prev.ffmpeg_8-headless; }
                else { ffmpeg-full = prev.ffmpeg-headless; }
              );
          })
        (import ./nixpkgs/overlays/overlay.nix)
        #ethereum-nix.overlays.default
      ];

      getName = pkg: pkg.pname or (builtins.parseDrvName pkg.name).name;
      mkNixpkgsConfig = nixpkgsSource: {
        overlays = mkOverlays nixpkgsSource;
        config = {
          allowUnfreePredicate = pkg: builtins.elem (getName pkg) [
            "vscode"
            "copilot.vim"
            # sabnzbd (consider substituting)
            "unrar"
            "claude-code"
            "1password-cli"
          ];
          permittedInsecurePackages = [
            "intel-media-sdk-23.2.2"
          ];
          allowDeprecatedx86_64Darwin = "force";
        };
      };
      nixpkgsConfig = mkNixpkgsConfig nixpkgs;
      nixpkgsDarwinConfig = mkNixpkgsConfig nixpkgs-darwin;
      x86_64DarwinHomeModule = {
        # Legacy nix-shell/nix-build imports consult this file. Flake imports
        # continue setting the option explicitly above.
        xdg.configFile."nixpkgs/config.nix".text = ''
          {
            allowDeprecatedx86_64Darwin = "force";
          }
        '';
      };
    in
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          nixpkgsSource = if system == "x86_64-darwin" then nixpkgs-darwin else nixpkgs;
          pkgs = import nixpkgsSource {
            inherit system;
            overlays = mkOverlays nixpkgsSource;
            config.allowDeprecatedx86_64Darwin = "force";
          };
        in
        {
          packages = {
            atuin = pkgs.atuin;
            mbx = pkgs.mbx;
            caddyFull = pkgs.caddyFull;
            nix-dynamic-machines = pkgs.nix-dynamic-machines;
          } // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            # Refresh both platform-independent source bundles on Linux CI.
            caddy-source = (import nixpkgs {
              inherit system;
              overlays = mkOverlays nixpkgs;
            }).caddyFull.src;
            caddy-darwin-source = (import nixpkgs-darwin {
              inherit system;
              overlays = mkOverlays nixpkgs-darwin;
            }).caddyFull.src;
          };
          devShells.default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              age
              gnupg
              ssh-to-pgp
              ssh-to-age
              sops
            ];

          };
          formatter = pkgs.nixpkgs-fmt;
        }
      ) //
    (
      let
        nixosSystem = withCache nixpkgs.lib.nixosSystem;
      in
      {
        nixosConfigurations = {
          # u3 macbook vmware vm
          mifflin = nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit home-manager self; };
            modules = [
              ./hosts/mifflin/configuration.nix
              clipway.nixosModules.default
              ./nixos/common.nix
              sops-nix.nixosModules.sops
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
              sops-nix.nixosModules.sops
              ./hosts/finch/configuration.nix
              ./nixos/common.nix
              impermanence.nixosModules.impermanence
              home-manager.nixosModules.home-manager
              {
                nixpkgs = nixpkgsConfig;
                home-manager.useGlobalPkgs = true;
                home-manager.useUserPackages = true;
                home-manager.users.cody.imports = [
                  ./home-manager/home-supermin.nix
                ];
              }
            ];
          };

          robin = nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit self; };
            modules = [
              sops-nix.nixosModules.sops
              disko.nixosModules.disko
              ./hosts/robin/configuration.nix
              ./nixos/common.nix
              impermanence.nixosModules.impermanence
              home-manager.nixosModules.home-manager
              {
                virtualisation.vmVariantWithDisko = {
                  users.users.nixosvmtest.isSystemUser = true;
                  users.users.nixosvmtest.initialPassword = "test";
                  users.groups.nixosvmtest = { };
                  users.users.nixosvmtest.group = "nixosvmtest";
                };
              }
              ({ pkgs, ... }: {
                nixpkgs = nixpkgsConfig;
                home-manager.useGlobalPkgs = true;
                home-manager.useUserPackages = true;
                home-manager.users.cody.imports = [
                  ./home-manager/home-supermin.nix
                ];
                home-manager.users.cody.home.packages = [
                  pkgs.gh
                ];
              })
            ];
          };

          # local storage
          arnold = nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit home-manager self; };
            modules = [
              #ethereum-nix.nixosModules.default
              sops-nix.nixosModules.sops
              ./hosts/arnold/configuration.nix
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

          # x220
          forbes = nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit home-manager self; };
            modules = [
              ./nixos/common.nix
              ./hosts/forbes/configuration.nix
              {
                nixpkgs = nixpkgsConfig;
              }
            ];
          };

          # router
          ward = nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit home-manager self; };
            modules = [
              #ethereum-nix.nixosModules.default
              sops-nix.nixosModules.sops
              ./hosts/ward/configuration.nix
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
              ./hosts/findley/configuration.nix
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
          constance = nixosSystem {
            system = "x86_64-linux";
            specialArgs = { inherit home-manager; };
            modules = [
              ./hosts/constance/configuration.nix
            ];
          };

          # work vmware vm
          trunix = nixosSystem {
            system = "x86_64-linux";
            modules = [
              ./nixos/trunix/configuration.nix
            ];
          };

          # work utm vm
          maclay = nixosSystem {
            system = "aarch64-linux";
            specialArgs = { inherit home-manager self; };
            modules = [
              ./nixos/common.nix
              ./hosts/maclay/configuration.nix
              home-manager.nixosModules.home-manager
              ({ pkgs, ... }: {
                nixpkgs = nixpkgsConfig;
                home-manager.useGlobalPkgs = true;
                home-manager.useUserPackages = true;
                home-manager.users.cody.imports = [
                  ./home-manager/home.nix
                ];
                home-manager.users.cody.home.packages = [
                  pkgs.nerdctl
                ];
              })
            ];
          };

          # x-mbp vmware vm
          adams = nixosSystem {
            system = "x86_64-linux";

            modules = [
              ./nixos/adams/configuration.nix
            ];
          };

          calvin = nixosSystem {
            system = "x86_64-linux";

            modules = [
              ./nixos/calvin/configuration.nix
            ];
          };
        };

        # Build darwin flake using:
        # $ darwin-rebuild build --flake .#x-mbp
        darwinConfigurations."x-mbp" = (withCache nix-darwin-26-05.lib.darwinSystem) {
          specialArgs = { inherit self; };
          modules = [
            ({ ... }: {
              users.users.x = {
                name = "x";
                home = "/Users/x";
              };
              nixpkgs.hostPlatform = "x86_64-darwin";
              ids.gids.nixbld = 350;
              nixpkgs.config.allowDeprecatedx86_64Darwin = "force";
            })
            ./nix-darwin/configuration.nix
            home-manager-26-05.darwinModules.home-manager
            {
              nixpkgs = nixpkgsDarwinConfig;
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.x.imports = [
                ./nix-darwin/home.nix
                ./home-manager/home.nix
                x86_64DarwinHomeModule
              ];
            }
          ];
        };

        darwinConfigurations."u3" = (withCache nix-darwin-26-05.lib.darwinSystem) {
          specialArgs = { inherit self; };
          modules = [
            sops-nix.darwinModules.sops
            ({ pkgs, ... }: {
              users.users.cody = {
                name = "cody";
                home = "/Users/cody";
              };
              nixpkgs.hostPlatform = "x86_64-darwin";
              nixpkgs.config.allowDeprecatedx86_64Darwin = "force";
              nix.enable = true;
              nix.package = pkgs.lix;
              nix.settings.use-case-hack = false;
              system.primaryUser = "cody";
              #nix.extraOptions = ''
              #  #upgrade-nix-store-path-url = "https://install.determinate.systems/nix-upgrade/stable/universal";
              #'';

              # FIXME: included because we don't include `nixos/common.nix` here.
              #p.nix.buildMachines.ward.enable = true;
              #p.nix.buildMachines.ward.sshKey = "/etc/nix/keys/nix_ed25519";
            })
            ./nix-darwin/configuration.nix
            #./modules/build-machines.nix
            home-manager-26-05.darwinModules.home-manager
            {
              nixpkgs = nixpkgsDarwinConfig;
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.cody = {
                imports = [
                  ./nix-darwin/home.nix
                  ./home-manager/home.nix
                  x86_64DarwinHomeModule
                  ./hosts/u3/home.nix
                ];

              };
            }
            ./hosts/u3/darwin.nix
          ];
        };

        darwinConfigurations."RVW-LYY7YT7329M" = (withCache nix-darwin.lib.darwinSystem) {
          specialArgs = { inherit self; };
          modules = [
            ({ ... }: {
              system.primaryUser = "codyschafer";
              users.users.codyschafer = {
                name = "codyschafer";
                home = "/Users/codyschafer";
              };
              nixpkgs = nixpkgsConfig // {
                hostPlatform = "aarch64-darwin";
              };
              nix.settings.use-case-hack = false;
              nix.extraOptions = ''
                bash-prompt-prefix = (nix:$name)\040
                #upgrade-nix-store-path-url = "https://install.determinate.systems/nix-upgrade/stable/universal";
              '';
            })
            ./nix-darwin/configuration.nix
            ({ pkgs, ... }: {
              environment.systemPackages = with pkgs; [
                mkcert
                nss.tools
                helm-docs
                kubeswitch
                kubectx
                krew
                kubectl
                kubectl-df-pv
                (wrapHelm kubernetes-helm {
                  plugins = with kubernetes-helmPlugins; [
                    helm-diff
                    helm-schema
                    helm-docs
                  ];
                })
              ];

              services.dnsmasq = {
                enable = true;
                addresses = {
                  ".test" = "192.168.6.137";
                };
                bind = "127.0.0.111";
              };

              homebrew = {
                enable = true;
                casks = [
                  "rivian/rvt/rvt"
                ];
                taps = [
                  {
                    name = "rivian/rvt";
                    clone_target = "ssh://git@gitlab.rivianvw.io/co/vehicle-and-fleet-applications/sdk-and-libraries/homebrew-rvt";
                    force_auto_update = true;
                    trusted = true;
                  }
                ];
                enableZshIntegration = true;
              };
            })
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
            ({ pkgs, ... }: {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.codyschafer = {
                imports = [
                  ./nix-darwin/home.nix
                  ./home-manager/home.nix
                ];
                home.file = {
                  ".ssh/config.d/1password".text = ''
                    Host *
                            IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
                  '';
                };
                home.packages = with pkgs; [
                  _1password-cli
                ];
                programs.claude-code.enable = true;
                programs.direnv.config = {
                  whitelist = { prefix = [ "/Volumes/dev/rivian/" ]; };
                };
              };
            })
          ];
        };

      } // (
        let
          system = "x86_64-linux";
          pkgs = (import nixpkgs {
            inherit system;
            overlays = mkOverlays nixpkgs;
            inherit (nixpkgsConfig) config;
          });
        in
        {

          # chromeos
          # system setup:
          # 1. `apt update && apt install git`
          # 2. do a nixos multi-user install
          # 3. add `experimental-features = nix-command flake` to /etc/nix/nix.conf
          # 4. modify /etc/ssh/ssh_config to kill the warning about gssapiauthentication
          # 5. ssh-keygen -t ed25519
          homeConfigurations."cody@penguin" = (withCache home-manager.lib.homeManagerConfiguration) {
            inherit pkgs;

            modules = [
              ({ ... }: {
                home.username = "cody";
                home.homeDirectory = "/home/cody";
              })
              ./home-manager/home.nix
              ({ lib, ... }: {
                programs.mbx.enable = true;
                programs.git.signing = {
                  format = lib.mkForce "ssh";
                  key = lib.mkForce "~/.ssh/id_ed25519";
                  signByDefault = lib.mkForce true;
                };
                xdg.configFile."containers/registries.conf".text = ''
                  unqualified-search-registries = ["docker.io"]
                '';

                # try to get gpu working
                targets.genericLinux.enable = true;
              })
            ];
          };

          # arnold
          homeConfigurations."y@arnold" = (withCache home-manager.lib.homeManagerConfiguration) {
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
          homeConfigurations."x@adams" = (withCache home-manager.lib.homeManagerConfiguration) {
            inherit pkgs;

            modules = [
              ({ ... }: {
                home.username = "x";
                home.homeDirectory = "/home/x";
              })
              ./home-manager/home.nix
            ];
          };

          homeConfigurations."cody@constance" = (withCache home-manager.lib.homeManagerConfiguration) {
            inherit pkgs;

            modules = [
              ({ ... }: {
                home.username = "cody";
                home.homeDirectory = "/home/cody";
              })
              ./home-manager/home.nix
            ];
          };

          homeConfigurations."cody@arch1" = (withCache home-manager.lib.homeManagerConfiguration) {
            inherit pkgs;

            modules = [
              ({ ... }: {
                home.username = "cody";
                home.homeDirectory = "/home/cody";
              })
              ./home-manager/home.nix
              ./hosts/arch1/home.nix
            ];
          };
        }
      )
    );
}
