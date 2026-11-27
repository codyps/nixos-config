{ config, self, ... }:
{
  imports = [ ../../nixos-modules/actions-vm-scaler.nix ./actions-vm-storage.nix ];

  # Each scale set maintains a listener per repository granted to the App.
  systemd.services.actions-vm-scaler.serviceConfig.LimitNOFILE = "65536:524288";

  services.actions-vm-scaler = {
    scaleSets.windows = {
      capacity = 1;
      networkOctet = 80;
      macSlotOffset = 32;
      imageConfigFile = "/var/lib/actions-vm/images/windows11-v2/vm.json";
      settings = {
        scale_set = "warbler-windows";
        vm.guest_os = "windows";
      };
    };
    scaleSets.linux = {
      capacity = 1;
      networkOctet = 81;
      macSlotOffset = 64;
      imageConfigFile = "${self.packages.x86_64-linux.actions-linux-image}/vm.json";
      settings.scale_set = "warbler-linux-vm";
    };
    enable = true;
    capacity = 1;
    privateKeyFile = config.sops.secrets.garm-app-key.path;
    imageConfigFile = "/var/lib/actions-vm-images/sequoia-clt-fda-v3/vm.json";
    settings = {
      scale_set = "warbler-macos-intel";
      # Discover repositories granted to the existing App installation.
      app_id = "5099875";
      installation_id = 165554289;
      runner_group_id = 1;
      discovery_interval_secs = 60;
    };
  };
}
