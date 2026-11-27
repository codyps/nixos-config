{ config, pkgs, hardwareIdentities, ... }:
{
  services.usbguard = {
    # Pinned nixpkgs already includes the required C++20 build fix.
    enable = true;
    package = pkgs.usbguard.overrideAttrs (old: {
      # Classify imported devices using the kernel path, which USB descriptors
      # cannot set. Root hubs retain USBGuard's normal controller handling.
      postPatch = (old.postPatch or "") + ''
        substituteInPlace src/Library/DeviceBase.cpp \
          --replace-fail '    if (!hasPrefix(getPort(), "usb")) {' \
          '    const bool is_usb_device = !hasPrefix(getPort(), "usb");
            if (is_usb_device && hasPrefix(sysfs_device.getPath(), "/devices/platform/vhci_hcd.")) {
              connect_type = "usbip-vhci";
            } else if (is_usb_device) {'
      '';
    });
    IPCAllowedUsers = [ "root" ];
    IPCAllowedGroups = [ ];
    implicitPolicyTarget = "block";
    presentDevicePolicy = "apply-policy";
    insertedDevicePolicy = "apply-policy";
    # Keep the kernel's root hubs; this does not allow external USB hubs.
    presentControllerPolicy = "keep";
    restoreControllerDeviceState = false;
    ruleFile = "${config.services.hardwareIdentities.stateDirectory}/current/usbguard.rules";
  };
  services.hardwareIdentities.templates."usbguard.rules".text = ''
    # USBGuard derives this connection type from kernel sysfs ancestry.
    allow with-connect-type "usbip-vhci"

    # Logitech receiver inspected on Warbler, 2026-09-16. Keep in this port.
    # Do not pin parent-hash: root-hub descriptors change with kernel updates.
    allow id 046d:c52b hash "${hardwareIdentities "warbler" [ "usb" "devices" "logitechReceiver" "descriptorHash" ]}" via-port "6-2" with-interface equals { 03:01:01 03:01:02 03:00:00 }
  '';
}
