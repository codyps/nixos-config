{ config, pkgs, ... }:
{
  sops.useSystemdActivation = true;
  sops.age.sshKeyPaths = [ "/persist/ssh/ssh_host_ed25519_key" ];
  sops.gnupg.sshKeyPaths = [ ];
  sops.secrets.wifi = {
    sopsFile = ./secrets.yaml;
    mode = "0600";
    # A regular copy keeps iwd's writes away from the SOPS generation symlink.
    restartUnits = [ "iwd.service" ];
  };
  networking.useDHCP = false;
  networking.networkmanager.enable = false;
  networking.wireless.enable = false;
  networking.wireless.iwd = {
    enable = true;
    settings = {
      General.EnableNetworkConfiguration = false;
      DriverQuirks.DefaultInterface = "*";
    };
  };
  systemd.services.iwd = {
    after = [ "sops-install-secrets.service" ];
    requires = [ "sops-install-secrets.service" ];
    serviceConfig.ReadWritePaths = [ "/persist/credstore" ];
    preStart = ''
      ${pkgs.coreutils}/bin/install -d -m 0700 /var/lib/iwd /persist/credstore
      ${pkgs.coreutils}/bin/install -m 0600 ${config.sops.secrets.wifi.path} /var/lib/iwd/billy.psk
      # Authoritative input for TPM sealing at bootloader installation time.
      ${pkgs.coreutils}/bin/install -m 0600 ${config.sops.secrets.wifi.path} /persist/credstore/wifi
    '';
  };
  systemd.tmpfiles.rules = [ "d /persist/credstore 0700 root root -" ];
  systemd.network = {
    enable = true;
    links."10-crow-wifi" = {
      matchConfig.PermanentMACAddress = "44:0f:b4:22:d8:38";
      linkConfig.Name = "wlp6s0";
    };
    networks."20-wifi" = {
      matchConfig.Name = "wlp6s0";
      networkConfig = { DHCP = "yes"; IPv6AcceptRA = true; };
      dhcpV4Config.ClientIdentifier = "mac";
      linkConfig.RequiredForOnline = "routable";
    };
  };
  boot.initrd.systemd.network.links."10-crow-wifi" = config.systemd.network.links."10-crow-wifi";
  services.resolved.enable = true;
}
