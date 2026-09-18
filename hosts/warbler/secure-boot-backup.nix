{ writeShellApplication, coreutils, efitools, sbctl, systemd, util-linux, nettools }:
writeShellApplication {
  name = "warbler-secure-boot-backup";
  runtimeInputs = [ coreutils efitools sbctl systemd util-linux nettools ];
  text = builtins.readFile ./secure-boot-backup.sh;
}
