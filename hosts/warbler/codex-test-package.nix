{ pkgs }:
let
  bubblewrap = pkgs.callPackage ./ai-bubblewrap.nix { };
in
pkgs.runCommand "codex-test-package" { } ''
  mkdir -p "$out/bin" "$out/codex-path" "$out/codex-resources"
  # Bypass Nixpkgs' wrapper, which prepends its unpatched Bubblewrap.
  cp ${pkgs.codex}/bin/.codex-wrapped "$out/bin/codex"
  cp ${pkgs.codex}/bin/codex-code-mode-host "$out/bin/"
  cp ${pkgs.ripgrep}/bin/rg "$out/codex-path/rg"
  cp ${bubblewrap}/bin/bwrap "$out/codex-resources/bwrap"
  cat > "$out/codex-package.json" <<'EOF'
  ${builtins.toJSON { version = pkgs.codex.version; target = "x86_64-unknown-linux-gnu"; entrypoint = "bin/codex"; }}
  EOF
''
