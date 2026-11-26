{ config, ... }:
{
  imports = [ ../../nixos-modules/actions-vm-scaler.nix ./actions-vm-storage.nix ];

  # Discovery maintains one listener per repository granted to the App.
  systemd.services.actions-vm-scaler.serviceConfig.LimitNOFILE = "65536:524288";
  systemd.services.actions-vm-scaler-windows.serviceConfig.LimitNOFILE = "65536:524288";

  services.actions-vm-scaler = {
    instances.windows = {
      enable = true;
      capacity = 1;
      networkOctet = 80;
      macSlotOffset = 32;
      privateKeyFile = config.sops.secrets.garm-app-key.path;
      imageConfigFile = "/var/lib/actions-vm/images/windows11-v2/vm.json";
      settings = {
        scale_set = "warbler-windows";
        app_id = "5099875";
        installation_id = 165554289;
        runner_group_id = 1;
        discovery_interval_secs = 60;
        startup_timeout_secs = 900;
        job_timeout_secs = 21600;
        vm.guest_os = "windows";
      };
    };
    enable = true;
    capacity = 1;
    privateKeyFile = config.sops.secrets.garm-app-key.path;
    imageConfigFile = "/var/lib/actions-vm-images/sequoia-clt-fda-v3/vm.json";
    settings = {
      # Discover repositories granted to the existing App installation.
      scale_set = "warbler-macos-intel";
      app_id = "5099875";
      installation_id = 165554289;
      runner_group_id = 1;
      discovery_interval_secs = 60;
      startup_timeout_secs = 900;
      job_timeout_secs = 21600;
    };
  };
}
