{ config, lib, pkgs, ... }:
let
  cfg = config.hardware.msA2.powerLed;
  helper = pkgs.stdenv.mkDerivation {
    pname = "ms-a2-power-led";
    version = "1";
    src = ./power-led.c;
    dontUnpack = true;
    buildPhase = ''
      runHook preBuild
      $CC -O2 -Wall -Wextra -Werror "$src" -o ms-a2-power-led
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 ms-a2-power-led "$out/bin/ms-a2-power-led"
      runHook postInstall
    '';
    meta.platforms = [ "x86_64-linux" ];
  };
in
{
  imports = [ ../../modules/admin-commands.nix ];

  options.hardware.msA2.powerLed = {
    enable = lib.mkEnableOption "Minisforum MS-A2 power LED brightness control";
    bootBrightness = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 0 255);
      default = null;
      description = "Power LED PWM applied during Linux startup. Null retains the BIOS setting. Does not change firmware NVRAM or brightness during POST.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.adminCommands.commands.power-led-brightness = [ "${helper}/bin/ms-a2-power-led" ];
    systemd.services.ms-a2-power-led = lib.mkIf (cfg.bootBrightness != null) {
      description = "Set Minisforum MS-A2 power LED brightness";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${helper}/bin/ms-a2-power-led ${toString cfg.bootBrightness}";
      };
    };
  };
}
