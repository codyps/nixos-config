# nix eval --impure --json --expr 'let f = builtins.getFlake ("path:" + toString ./.); in import ./scripts/check-nix-caches.nix f'
flake:
let
  expected = (import ../flake.nix).nixConfig;
  check = kind: configuration:
    let
      config = configuration.config;
      settings = config.nix.settings;
      hasAll = setting: builtins.all
        (value: builtins.elem value (settings.${setting} or [ ]))
        expected.${setting};
      # Force generation of the actual config-file derivation, not just options.
      source = if kind == "home" then
        config.xdg.configFile."nix/nix.conf".source
      else config.environment.etc."nix/nix.conf".source;
    in
    assert hasAll "extra-substituters";
    assert hasAll "extra-trusted-public-keys";
    assert config.nix.enable or true;
    assert kind != "home" || config.nix.package != null;
    builtins.seq source.drvPath true;
in {
  nixos = builtins.mapAttrs (_: check "nixos") flake.nixosConfigurations;
  darwin = builtins.mapAttrs (_: check "darwin") flake.darwinConfigurations;
  home = builtins.mapAttrs (_: check "home") flake.homeConfigurations;
}
