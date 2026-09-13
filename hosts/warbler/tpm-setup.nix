{ config, pkgs, ... }:
{
  environment.etc."warbler-tpm.json".text = builtins.toJSON {
    disk = "/dev/disk/by-partlabel/disk-system-crypt";
    policy = config.boot.lanzaboote.measuredBoot.pcrlockPolicy;
    diskUnlock = config.warbler.tpmUnlock.enable;
    pcrlock = "${config.systemd.package}/lib/systemd/systemd-pcrlock";
  };
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "warbler-tpm-setup";
      runtimeInputs = with pkgs; [ python3 systemd cryptsetup openssh util-linux ];
      text = ''
        exec python3 ${./tpm-setup.py} "$@"
      '';
    })
  ];
}
