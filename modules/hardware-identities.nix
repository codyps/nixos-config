{ config, lib, options, pkgs, ... }:
let
  scripts = pkgs.runCommand "hardware-provisioning-scripts" { } ''
    mkdir -p "$out"
    cp ${../scripts/hardware-identities.py} "$out/hardware-identities.py"
    cp ${../scripts/hardware-nix.py} "$out/hardware-nix.py"
  '';
  command = pkgs.writeShellApplication {
    name = "hardware-source";
    runtimeInputs = [ pkgs.python3 pkgs.git pkgs.sops pkgs.gnupg ];
    text = ''
      exec python3 ${scripts}/hardware-identities.py "$@"
    '';
  };
  nix = pkgs.writeShellApplication {
    name = "nix";
    runtimeInputs = [ pkgs.python3 pkgs.git pkgs.sops pkgs.gnupg ];
    text = ''
      exec python3 ${scripts}/hardware-nix.py ${config.nix.package}/bin/nix "$@"
    '';
  };
  fixture = builtins.pathExists ../.hardware-fixture;
  rejectFixture = ''
    echo "Refusing to activate synthetic hardware fixtures. Rebuild with local SOPS settings." >&2
    exit 1
  '';
in
{
  imports = [ ./admin-commands.nix ];
  config = lib.mkMerge [
    { programs.adminCommands.commands.hardware-source = [ "${command}/bin/hardware-source" ]; }
    (lib.optionalAttrs (options ? environment.systemPackages) {
      environment.systemPackages = [ (lib.hiPrio nix) ];
    })
    (lib.optionalAttrs (options ? home.packages) {
      home.packages = [ (lib.hiPrio nix) ];
    })
    (lib.optionalAttrs (options ? system.preSwitchChecks) {
      system.preSwitchChecks = lib.mkIf fixture { rejectHardwareFixtures = rejectFixture; };
      # Sort before normal activation snippets, including direct installer activation.
      system.activationScripts."00-hardware-fixtures" = lib.mkIf fixture rejectFixture;
    })
    (lib.optionalAttrs (options ? system.activationScripts && !(options ? system.preSwitchChecks)) {
      system.activationScripts.preActivation.text = lib.mkIf fixture (lib.mkBefore rejectFixture);
    })
    (lib.optionalAttrs (options ? home.activation) {
      home.activation.rejectHardwareFixtures = lib.mkIf fixture
        (lib.hm.dag.entryBefore [ "checkLinkTargets" "writeBoundary" ] rejectFixture);
    })
  ];
}
