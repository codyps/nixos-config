{ pkgs }:
let
  python = pkgs.python3.withPackages (p: [ p.tomlkit ]);
in
pkgs.writeShellScriptBin "codex-configure" ''
  exec ${python}/bin/python3 ${../scripts/codex-configure.py} "$@"
''
