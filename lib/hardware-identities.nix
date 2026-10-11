# Only prepared, local sources contain the decrypted per-host settings.
host: path:
let
  file = ../hardware-identities.json;
  inventory =
    if builtins.pathExists file then builtins.fromJSON (builtins.readFile file)
    else throw "Hardware settings missing: use the managed nix command, or bootstrap with sys hardware-source (docs/hardware-identities.md)";
in
builtins.foldl' (value: key: builtins.getAttr key value) inventory.${host} path
