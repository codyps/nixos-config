{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: 
let 
  uboot = pkgs.buildUBoot {
    defconfig = "mx6cuboxi_defconfig";
    extraMeta.platforms = ["armv7l-linux"];
    filesToInstall = ["SPL.bin" "u-boot.img"];
  };
in
{
  imports = [
    "${toString modulesPath}/profiles/base.nix"
    "${toString modulesPath}/installer/sd-card/sd-image.nix"
  ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  boot.consoleLogLevel = lib.mkDefault 7;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.kernelParams = [
    "console=ttymxc0,115200n8"
    "console=tty0"
  ];

  sdImage = {
    populateFirmwareCommands = "";
    populateRootCommands = ''
      mkdir -p ./files/boot
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot
    '';
    postBuildCommands = ''
      dd if=${uboot}/SPL of=$img bs=1k seek=1 conv=notrunc
      dd if=${uboot}/u-boot.img of= $img bs=1k seek=69 conv=notrunc
    '';
  };

  formatAttr = "sdImage";
  fileExtension = ".img.*";
}
