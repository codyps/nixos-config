# Enumerate roots without evaluating their complete derivation graphs.
flake:
let
  runners = {
    x86_64-linux = "ubuntu-24.04";
    aarch64-linux = "ubuntu-24.04-arm";
    x86_64-darwin = "macos-15-intel";
    aarch64-darwin = "macos-15";
  };
  entries = kind: configurations: suffix:
    builtins.map
      (name:
        let
          configuration = configurations.${name};
          system = configuration.pkgs.stdenv.hostPlatform.system;
        in {
          inherit kind name system;
          runner = runners.${system};
          target = ".#${kind}.${builtins.toJSON name}.${suffix}";
        })
      (builtins.attrNames configurations);
in {
  include =
    entries "nixosConfigurations" flake.nixosConfigurations "config.system.build.toplevel"
    ++ entries "homeConfigurations" flake.homeConfigurations "activationPackage"
    ++ entries "darwinConfigurations" flake.darwinConfigurations "system"
    # Configurations need not reference every exported package on every platform.
    # Keep package coverage automatic, including the Caddy source bundles.
    ++ builtins.concatMap
      (system: builtins.map
        (name: {
          kind = "packages";
          inherit name system;
          runner = runners.${system};
          target = ".#packages.${builtins.toJSON system}.${builtins.toJSON name}";
        })
        (builtins.attrNames flake.packages.${system}))
      (builtins.attrNames flake.packages);
}
