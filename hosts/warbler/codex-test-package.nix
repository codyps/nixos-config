{ pkgs }:
let
  bubblewrap = pkgs.callPackage ../../nixos-modules/ai-container/ai-bubblewrap.nix { };
in
pkgs.runCommand "codex-test-package" { } ''
  mkdir -p "$out/bin" "$out/codex-path" "$out/codex-resources"
  # Bypass older Nixpkgs wrappers, which prepend unpatched Bubblewrap.
  # Newer packages install the executable directly, without a wrapper.
  codex=${pkgs.codex}/bin/.codex-wrapped
  if [ ! -e "$codex" ]; then
    codex=${pkgs.codex}/bin/codex
  fi
  cp "$codex" "$out/bin/codex"
  cp ${pkgs.codex}/bin/codex-code-mode-host "$out/bin/"
  cp ${pkgs.ripgrep}/bin/rg "$out/codex-path/rg"
  cp ${bubblewrap}/bin/bwrap "$out/codex-resources/bwrap"
  cat > "$out/codex-package.json" <<'EOF'
  ${builtins.toJSON { version = pkgs.codex.version; target = "x86_64-unknown-linux-gnu"; entrypoint = "bin/codex"; }}
  EOF
''
