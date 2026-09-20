{ lib
, writeShellApplication
, callPackage
, device
, mapperName ? "cryptroot"
}:
let
  volumeKeyId = callPackage ../../scripts/luks-volume-key-id.nix { };
in
writeShellApplication {
  name = "root-volume-key-id";
  text = ''
    exec ${lib.getExe volumeKeyId} --device ${lib.escapeShellArg device} --name ${lib.escapeShellArg mapperName} "$@"
  '';
  meta.platforms = lib.platforms.linux;
}
