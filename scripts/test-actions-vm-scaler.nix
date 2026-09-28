# nix eval --impure --json --file scripts/test-actions-vm-scaler.nix
let
  flake = builtins.getFlake ("path:" + toString ../.);
  lib = flake.inputs.nixpkgs.lib;
  evaluate = extra: (lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      ../nixos-modules/actions-vm-scaler.nix
      {
        system.stateVersion = "26.05";
        fileSystems."/" = { device = "/dev/root"; fsType = "ext4"; };
        boot.loader.grub.enable = false;
      }
      extra
    ];
  }).config;
  enabled = {
    services.actions-vm-scaler = {
      enable = true;
      privateKeyFile = "/run/secrets/app-key";
      capacity = 2;
      settings = {
        discovery_interval_secs = 60;
        scale_set = "test-macos";
        app_id = "123";
        installation_id = 456;
        vm = {
          base_disk = "/images/base.qcow2";
          opencore_disk = "/images/OpenCore.qcow2";
          firmware_code = "/images/code.fd";
          firmware_vars = "/images/vars.fd";
          hardware_args = [ "-machine" "q35" "-cpu" "host" ];
        };
      };
    };
  };
  on = evaluate enabled;
  off = evaluate { };
  invalid = evaluate (lib.recursiveUpdate enabled {
    services.actions-vm-scaler.privateKeyFile = "/nix/store/example-key";
  });
  unit = on.systemd.services.actions-vm-scaler.serviceConfig;
in
assert builtins.all (x: x.assertion) on.assertions;
assert !(off.systemd.services ? actions-vm-scaler);
assert !(off.networking.nftables.tables ? actions-vm-isolation);
assert unit.User == "actions-vm-scaler";
assert unit.KillMode == "mixed";
assert unit.LoadCredential == [ "github-app-key:/run/secrets/app-key" ];
assert unit.ProtectSystem == "strict";
assert unit.StateDirectoryMode == "0700";
assert !(on.networking.firewall.filterForward);
assert lib.hasInfix "10.78.0.0/24" on.networking.nftables.tables.actions-vm-isolation.content;
assert builtins.any (x: !x.assertion && lib.hasInfix "runtime secret" x.message) invalid.assertions;
{
  passed = true;
  service = on.systemd.units."actions-vm-scaler.service".text;
  dhcp = on.systemd.units."actions-vm-dhcp.service".text;
  network = on.systemd.units."actions-vm-network.service".text;
  firewall = on.networking.nftables.tables.actions-vm-isolation.content;
  antispoof = on.networking.nftables.tables.actions-vm-antispoof.content;
  toplevel = on.system.build.toplevel.drvPath;
}
