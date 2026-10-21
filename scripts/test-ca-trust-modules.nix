# nix eval --impure --json --file scripts/test-ca-trust-modules.nix
let
  flake = builtins.getFlake ("path:" + toString ../.);
  extraCA = flake.inputs.nixpkgs + "/pkgs/by-name/ca/cacert/test-cert-file.crt";
  linux = (flake.inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      ../nixos-modules/ca-trust.nix
      { system.stateVersion = "26.05"; security.pki.certificateFiles = [ extraCA ]; }
    ];
  }).config;
  darwin = input: system: (input.lib.darwinSystem {
    inherit system;
    modules = [
      ../nix-darwin/modules/ca-trust.nix
      {
        system.stateVersion = 6;
        nixpkgs.config.allowDeprecatedx86_64Darwin = "force";
        security.pki.certificateFiles = [ extraCA ];
      }
    ];
  }).config;
  intel = darwin flake.inputs.nix-darwin-26-05 "x86_64-darwin";
  arm = darwin flake.inputs.nix-darwin "aarch64-darwin";
  home = (flake.inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = flake.nixosConfigurations.robin.pkgs;
    modules = [
      ../home-manager/ca-trust.nix
      { home.username = "test"; home.homeDirectory = "/home/test"; home.stateVersion = "23.05"; }
    ];
  }).config;
  checkSystem = c:
    assert c.environment.variables.SSL_CERT_FILE == toString c.programs.caTrust.bundle;
    assert c.environment.variables.NODE_OPTIONS == "--use-openssl-ca";
    assert c.environment.variables.HEX_CACERTS_PATH == toString c.programs.caTrust.bundle;
    assert c.environment.variables.ERL_AFLAGS == c.environment.variables.ERL_ZFLAGS;
    assert builtins.match ".*cacerts_path.*" c.environment.variables.ERL_AFLAGS != null;
    assert builtins.elem extraCA c.security.pki.certificateFiles;
    assert builtins.elem "emSign ECC Root CA - G3" c.security.pki.caCertificateBlacklist;
    true;
in
assert checkSystem linux;
assert checkSystem intel;
assert checkSystem arm;
assert linux.systemd.globalEnvironment.SSL_CERT_FILE == toString linux.programs.caTrust.bundle;
assert !(linux.systemd.globalEnvironment ? NODE_OPTIONS);
assert !(intel.launchd.user.envVariables ? NODE_OPTIONS);
assert builtins.toJSON home.home.sessionVariables.SSL_CERT_FILE == home.systemd.user.sessionVariables.SSL_CERT_FILE;
assert !(home.systemd.user.sessionVariables ? NODE_OPTIONS);
{
  passed = true;
  linuxBundle = toString linux.programs.caTrust.bundle;
  intelBundle = toString intel.programs.caTrust.bundle;
  armBundle = toString arm.programs.caTrust.bundle;
  standaloneHomeBundle = home.home.sessionVariables.SSL_CERT_FILE;
}
