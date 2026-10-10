# Provisioning adds this file only to a disposable path: flake, never to Git.
host: key:
let
  file = ../hardware-identities.json;
  inventory =
    if builtins.pathExists file then builtins.fromJSON (builtins.readFile file)
    else throw "Hardware inventory missing: use sys hardware-source run -- nix ... (see docs/hardware-identities.md)";
in
inventory.${host}.${key}
