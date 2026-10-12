{ config, hardwareIdentities, ... }:
{
  services.usbguard = {
    # Pinned nixpkgs already includes the required C++20 build fix.
    enable = true;
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
    # Logitech receiver inspected on Warbler, 2026-09-16. Keep in this port.
    # Do not pin parent-hash: root-hub descriptors change with kernel updates.
    allow id 046d:c52b hash "${hardwareIdentities "warbler" [ "usb" "devices" "logitechReceiver" "descriptorHash" ]}" via-port "6-2" with-interface equals { 03:01:01 03:01:02 03:00:00 }
  '';
}
