{ lib, writeShellApplication, callPackage
, device ? "/dev/disk/by-partlabel/disk-system-crypt"
}:
let
  volumeKeyId = callPackage ../../scripts/luks-volume-key-id.nix { };
in
writeShellApplication {
  name = "warbler-root-volume-key-id";
  text = ''
    exec ${lib.getExe volumeKeyId} --device ${lib.escapeShellArg device} --name cryptroot "$@"
  '';
  meta.platforms = lib.platforms.linux;
}
