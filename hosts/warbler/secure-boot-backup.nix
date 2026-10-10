{ writeShellApplication, lib, coreutils, efitools, sbctl, systemd, util-linux, nettools, hostName ? "warbler" }:
writeShellApplication {
  name = "warbler-secure-boot-backup";
  runtimeInputs = [ coreutils efitools sbctl systemd util-linux nettools ];
  text = ''
    expected_host=${lib.escapeShellArg hostName}
  '' + builtins.readFile ./secure-boot-backup.sh;
}
