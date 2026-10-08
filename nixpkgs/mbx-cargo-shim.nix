{ pkgs, package ? pkgs.mbx }:
# Keep the upstream launcher byte-for-byte so mbx doctor recognizes it.
pkgs.runCommand "mbx-cargo-shim" { } ''
  ${pkgs.python3}/bin/python3 - ${package.src}/crates/mbx/src/cli/setup.rs "$out" <<'PYTHON'
  import pathlib, re, sys
  source = pathlib.Path(sys.argv[1]).read_bytes()
  match = re.search(rb'CARGO_SHIM_LAUNCHER:.*?br#"(.*?)"#;', source, re.S)
  if match is None or not match[1].startswith(b"#!/bin/sh\n"):
      raise SystemExit("mbx upstream Cargo shim format changed")
  pathlib.Path(sys.argv[2]).write_bytes(match[1])
  PYTHON
  chmod +x "$out"
''
