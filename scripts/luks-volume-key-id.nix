{ lib, writeShellApplication, python3, cryptsetup }:
writeShellApplication {
  name = "luks-volume-key-id";
  runtimeInputs = [ python3 ];
  text = ''
    exec python3 ${./luks-volume-key-id.py} --library ${lib.getLib cryptsetup}/lib/libcryptsetup.so "$@"
  '';
  meta.platforms = lib.platforms.linux;
}
