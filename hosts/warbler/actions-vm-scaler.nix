{ config, ... }:
{
  imports = [ ../../nixos-modules/actions-vm-scaler.nix ];

  services.actions-vm-scaler = {
    enable = true;
    capacity = 1;
    privateKeyFile = config.sops.secrets.garm-app-key.path;
    imageConfigFile = "/var/lib/actions-vm-images/sequoia-clt-auto-v1/vm.json";
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
