{ pkgs, ... }:
{
  # The ChatGPT file viewer streams remote Unix files through this absolute path.
  systemd.tmpfiles.rules = [
    "L+ /bin/cat - - - - ${pkgs.coreutils}/bin/cat"
  ];
}
