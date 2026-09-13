# Shared service artifacts, not a module. Keep platform supervision separate.
{ config, lib, pkgs, directory }:
let
  cfg = config.services.nix-dynamic-machines;
  rawCandidates = pkgs.writeText "nix-builder-candidates" (lib.concatLines (
    map (line: "always ${line}") cfg.alwaysBuilders
    ++ map (line: "probe ${line}") cfg.probeBuilders
  ));
  rawInitial = pkgs.writeText "nix-builder-initial-machines" (lib.concatLines cfg.alwaysBuilders);
  validationCandidates = pkgs.writeText "nix-builder-validation" (lib.concatLines (
    map (line: "always ${line}") (cfg.alwaysBuilders ++ cfg.probeBuilders)
  ));
  files = pkgs.runCommand "nix-dynamic-machines-files" { } ''
    # Validate with the actual parser, but classify every entry as always so
    # building a system configuration never contacts or wakes a builder.
    ${lib.getExe cfg.package} --candidates ${validationCandidates} \
      --output "$TMPDIR/validated-machines" --nix /nonexistent/nix
    mkdir -p "$out"
    cp ${rawCandidates} "$out/candidates"
    cp ${rawInitial} "$out/initial-machines"
  '';
  candidates = "${files}/candidates";
  initial = "${files}/initial-machines";
  initialize = pkgs.writeShellScript "initialize-nix-dynamic-machines" ''
    set -eu
    ${pkgs.coreutils}/bin/install -d -m 0755 -o 0 ${lib.escapeShellArg directory}
    if [ ! -e ${lib.escapeShellArg "${directory}/machines"} ]; then
      ${pkgs.coreutils}/bin/install -m 0644 -o 0 ${initial} ${lib.escapeShellArg "${directory}/machines"}
    fi
  '';
  arguments = [
    (lib.getExe cfg.package)
    "--watch"
    "--candidates"
    candidates
    "--output"
    "${directory}/machines"
    "--state"
    "${directory}/state.json"
    "--nix"
    "${config.nix.package}/bin/nix"
    "--timeout"
    (toString cfg.timeout)
    "--parallelism"
    (toString cfg.parallelism)
    "--healthy-interval"
    (toString cfg.healthyInterval)
    "--retry-interval"
    (toString cfg.retryInterval)
    "--max-retry-interval"
    (toString cfg.maxRetryInterval)
  ];
in
{
  inherit initialize arguments;
  builders = lib.concatStringsSep "; " (
    lib.optional (config.nix.buildMachines != [ ]) "@/etc/nix/machines"
    ++ [ "@${directory}/machines" ]
  );
  runner = pkgs.writeShellScript "run-nix-dynamic-machines" ''
    set -eu
    umask 022
    ${initialize}
    export PATH=${lib.makeBinPath [ pkgs.openssh config.nix.package pkgs.coreutils ]}
    exec ${lib.escapeShellArgs arguments}
  '';
}
