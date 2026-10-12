{ lib, options, pkgs, hardwareFixture, ... }:
let
  scripts = pkgs.runCommand "hardware-provisioning-scripts" { } ''
    mkdir -p "$out"
    cp ${../scripts/hardware-identities.py} "$out/hardware-identities.py"
  '';
  command = pkgs.writeShellApplication {
    name = "hardware-source";
    runtimeInputs = [ pkgs.python3 pkgs.git pkgs.sops pkgs.gnupg ];
    text = ''
      exec python3 ${scripts}/hardware-identities.py "$@"
    '';
  };
  fixture = hardwareFixture;
  rejectFixtureCommand = pkgs.writeShellScript "reject-hardware-fixtures" ''
    echo "Refusing to activate synthetic hardware fixtures. Rebuild with local SOPS settings." >&2
    exit 1
  '';
  # Keep the failure in a separate executable so ShellCheck can still analyze
  # the rest of Darwin's combined activation script.
  rejectFixture = ''
    ${rejectFixtureCommand} || exit 1
  '';
in
{
  imports = [ ./admin-commands.nix ];
  config = lib.mkMerge [
    {
      programs.adminCommands.commands.hardware-input = [ "${command}/bin/hardware-source" ];
      programs.adminCommands.commands.hardware-source = [ "${command}/bin/hardware-source" ];
    }
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
