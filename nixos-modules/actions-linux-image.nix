{ config, pkgs, modulesPath, ... }:
let
  rootLabel = "actions-linux";
  closure = pkgs.closureInfo { rootPaths = [ config.system.build.toplevel ]; };
in
{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    (modulesPath + "/image/repart.nix")
  ];

  networking.hostName = rootLabel;
  networking.useNetworkd = true;
  networking.useDHCP = true;
  boot.loader.grub.enable = false;
  boot.kernelModules = [ "sr_mod" "iso9660" ];
  boot.kernelParams = [ "console=ttyS0" ];
  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/${rootLabel}";
    fsType = "ext4";
  };

  users.mutableUsers = false;
  users.allowNoPasswordLogin = true;
  users.users.runner = {
    isNormalUser = true;
    extraGroups = [ "docker" ];
  };
  virtualisation.docker.enable = true;
  environment.systemPackages = [ pkgs.git ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  systemd.services.register-nix-paths = {
    description = "Register the NixOS image closure in the writable Nix store";
    before = [ "nix-daemon.service" "actions-vm-linux-runner.service" ];
    requiredBy = [ "nix-daemon.service" "actions-vm-linux-runner.service" ];
    unitConfig.ConditionPathExists = "/nix-path-registration";
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script = ''
      set -eu
      ${config.nix.package}/bin/nix-store --load-db < /nix-path-registration
      ln -sfn "$(readlink -f /run/current-system)" /nix/var/nix/gcroots/actions-linux-system
      rm /nix-path-registration
    '';
  };

  systemd.services.actions-vm-linux-runner = {
    description = "Disposable GitHub Actions runner";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.coreutils pkgs.util-linux ] ++ config.environment.systemPackages;
    unitConfig = {
      ConditionKernelCommandLine = "!actions-vm-image-maintenance";
      SuccessAction = "poweroff";
      FailureAction = "poweroff";
    };
    serviceConfig = {
      Type = "exec";
      RuntimeDirectory = "actions-vm-bootstrap";
      RuntimeDirectoryMode = "0700";
      PrivateMounts = true;
      ExecStart = "${pkgs.bash}/bin/bash ${../scripts/actions-vm-scaler/guest/linux-bootstrap.sh} ${pkgs.github-runner}/bin/Runner.Listener run --startuptype service";
    };
  };

  image.repart = {
    enable = true;
    name = rootLabel;
    sectorSize = 512;
    partitions = {
      esp = {
        contents."/EFI/BOOT/BOOTX64.EFI".source =
          "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";
        repartConfig = {
          Type = "esp";
          Format = "vfat";
          SizeMinBytes = "128M";
        };
      };
      root = {
        storePaths = [ config.system.build.toplevel ];
        contents."/nix-path-registration".source = "${closure}/registration";
        repartConfig = {
          Type = "root";
          Format = "ext4";
          Label = rootLabel;
          SizeMinBytes = "16G";
        };
      };
    };
  };
  system.stateVersion = "26.05";
}
