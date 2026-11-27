{ config, lib, pkgs, ... }:
let
  cfg = config.services.actions-vm-scaler;
  format = pkgs.formats.json { };
  package = pkgs.callPackage ../nixpkgs/actions-vm-scaler.nix { };
  scaleSetOptions = {
    capacity = lib.mkOption {
      type = lib.types.ints.between 1 32;
      default = 1;
      description = "Maximum concurrent VMs across all discovered repositories; each gets a dedicated isolated TAP.";
    };
    imageConfigFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime published vm.json path. Image settings are merged with settings.vm; module executable and TAP settings take precedence.";
    };
    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = "Scaler JSON settings. Omit github_url to discover all repositories granted to the App installation. The module supplies executable, state, key and TAP paths.";
    };
    networkOctet = lib.mkOption {
      type = lib.types.ints.between 1 254;
      default = 78;
      description = "Unique second octet of the private 10.x.0.0/24 runner network.";
    };
    macSlotOffset = lib.mkOption {
      type = lib.types.ints.between 0 224;
      default = 0;
      description = "Offset into the synthetic NIC slot range; use a distinct range per instance.";
    };
  };
  instanceOptions = scaleSetOptions // {
    privateKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime GitHub App PEM path, typically a SOPS secret. Never a Nix store path.";
    };
  };
  serviceName = name: if name == "default" then "actions-vm-scaler" else "actions-vm-scaler-${name}";
  stateDir = name: "/var/lib/${serviceName name}";
  activeInstances = lib.filterAttrs (_: instance: instance.enable) cfg.instances;
  sharedSettings = lib.filterAttrs
    (field: _: builtins.elem field [
      "app_id"
      "installation_id"
      "runner_group_id"
      "discovery_interval_secs"
    ])
    cfg.settings;
  grouped = lib.optionalAttrs cfg.enable ({ default = cfg; } // lib.mapAttrs
    (_: set: set // { settings = sharedSettings // set.settings; })
    cfg.scaleSets);
  active = grouped // activeInstances;
  macSlots = lib.concatMap (i: lib.range i.macSlotOffset (i.macSlotOffset + i.capacity - 1)) (lib.attrValues active);
  hostAddresses = lib.concatMap (i: i.ipv4.addresses) (lib.attrValues config.networking.interfaces);
  ipv4Number = address: lib.foldl' (number: octet: number * 256 + lib.toInt octet) 0 (lib.splitString "." address);
  subnetOverlaps = octet: address:
    let
      # Compare the shared prefix so broader host networks are also covered.
      block = lib.foldl' (n: _: n * 2) 1 (lib.replicate (32 - lib.min 24 address.prefixLength) null);
    in
    builtins.div (ipv4Number "10.${toString octet}.0.0") block == builtins.div (ipv4Number address.address) block;
  scaleSetModule = name: cfg:
    let
      unitName = serviceName name;
      controller = serviceName (if builtins.hasAttr name grouped then "default" else name);
      tablePrefix = if name == "default" then "actions-vm" else unitName;
      networkPrefix = if name == "default" then "avm" else "av${toString cfg.networkOctet}";
      bridge = "${networkPrefix}br0";
      taps = lib.genList (i: "${networkPrefix}${toString i}") cfg.capacity;
      mac = i: "52:54:00:78:00:${lib.fixedWidthString 2 "0" (lib.toHexString (cfg.macSlotOffset + i))}";
      ip = i: "10.${toString cfg.networkOctet}.0.${toString (10 + i)}";
      runtimeConfig = format.generate "actions-vm-scaler.json" (cfg.settings // {
        state_dir = stateDir name;
        private_key_file = "/run/credentials/${controller}.service/github-app-key";
        vm = (cfg.settings.vm or { }) // {
          qemu = "${pkgs.qemu_kvm}/bin/qemu-system-x86_64";
          qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img";
          xorriso = "${pkgs.xorriso}/bin/xorriso";
          inherit taps;
          mac_slot_offset = cfg.macSlotOffset;
        } // lib.optionalAttrs ((cfg.settings.vm.guest_os or "macos") == "windows") {
          tpm = (cfg.settings.vm.tpm or { }) // {
            swtpm = "${pkgs.swtpm}/bin/swtpm";
            socket_dir = if controller == unitName then "/run/${controller}/tpm" else "/run/${controller}/tpm-${name}";
          };
        };
      });
      networkSetup = pkgs.writeShellScript "actions-vm-network" ''
        set -eu
        ${pkgs.iproute2}/bin/ip link show ${bridge} >/dev/null 2>&1 || ${pkgs.iproute2}/bin/ip link add ${bridge} type bridge
        ${pkgs.iproute2}/bin/ip address replace 10.${toString cfg.networkOctet}.0.1/24 dev ${bridge}
        ${pkgs.iproute2}/bin/ip link set ${bridge} up
        ${lib.concatMapStringsSep "\n" (tap: ''
          # Replace a persistent TAP left behind by a previous service account.
          if [ -e /sys/class/net/${tap}/owner ] && [ "$(${pkgs.coreutils}/bin/cat /sys/class/net/${tap}/owner)" != "$(${pkgs.coreutils}/bin/id -u ${controller})" ]; then
            ${pkgs.iproute2}/bin/ip tuntap del dev ${tap} mode tap
          fi
          ${pkgs.iproute2}/bin/ip link show ${tap} >/dev/null 2>&1 || ${pkgs.iproute2}/bin/ip tuntap add dev ${tap} mode tap user ${controller}
          ${pkgs.iproute2}/bin/ip link set ${tap} master ${bridge}
          ${pkgs.iproute2}/bin/ip link set ${tap} type bridge_slave isolated on
          ${pkgs.iproute2}/bin/ip link set ${tap} up
        '') taps}
      '';
      networkService = "${tablePrefix}-network";
      dhcpService = "${tablePrefix}-dhcp";

    in
    {
      assertions = [
        { assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux"; message = "actions-vm-scaler requires x86_64 Linux/KVM."; }
        { assertion = builtins.match "[a-z][a-z0-9-]*" name != null; message = "Scaler instance names must be lowercase service names."; }
        { assertion = !(lib.any (subnetOverlaps cfg.networkOctet) hostAddresses); message = "Actions VM subnet for ${name} overlaps a configured host interface."; }
        { assertion = cfg.macSlotOffset + cfg.capacity <= 256; message = "Scaler synthetic NIC slots exceed one byte."; }
      ];
      inherit runtimeConfig dhcpService networkService;
      inherit (cfg) imageConfigFile;
      networking.nftables = {
        enable = true;
        tables."${tablePrefix}-isolation" = {
          family = "inet";
          content = ''
            chain input {
              type filter hook input priority -10; policy accept;
              iifname "${bridge}" udp dport { 53, 67 } accept
              iifname "${bridge}" tcp dport 53 accept
              iifname "${bridge}" drop
            }
            chain forward {
              type filter hook forward priority -10; policy accept;
              iifname "${bridge}" meta nfproto ipv6 drop
              iifname "${bridge}" ip saddr != 10.${toString cfg.networkOctet}.0.0/24 drop
              iifname "${bridge}" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } drop
              oifname "${bridge}" ct state established,related accept
              oifname "${bridge}" drop
            }
            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;
              ip saddr 10.${toString cfg.networkOctet}.0.0/24 oifname != "${bridge}" masquerade
            }
          '';
        };
        tables."${tablePrefix}-antispoof" = {
          family = "bridge";
          content = ''
            chain prerouting {
              type filter hook prerouting priority -300; policy accept;
              ${lib.concatStringsSep "\n" (lib.imap0 (i: tap: ''
                iifname "${tap}" ether saddr != ${mac i} drop
                iifname "${tap}" ether type ip6 drop
                iifname "${tap}" ether type ip ip saddr != { 0.0.0.0, ${ip i} } drop
                iifname "${tap}" ether type arp arp saddr ether != ${mac i} drop
                iifname "${tap}" ether type arp arp saddr ip != { 0.0.0.0, ${ip i} } drop
              '') taps)}
            }
          '';
        };
      };
      networking.firewall.interfaces.${bridge} = {
        allowedTCPPorts = [ 53 ];
        allowedUDPPorts = [ 53 67 ];
      };
      networking.firewall.extraForwardRules = ''
        iifname "${bridge}" accept
        oifname "${bridge}" ct state established,related accept
      '';
      systemd.services."${networkService}" = {
        description = "Private network for disposable Actions VMs";
        before = [ "${controller}.service" "${dhcpService}.service" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = networkSetup; };
      };
      systemd.services."${dhcpService}" = {
        requires = [ "${networkService}.service" ];
        after = [ "${networkService}.service" ];
        serviceConfig = {
          ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --user=root --conf-file=/dev/null --interface=${bridge} --bind-interfaces --except-interface=lo --dhcp-range=10.${toString cfg.networkOctet}.0.10,10.${toString cfg.networkOctet}.0.100,255.255.255.0,1h --dhcp-leasefile=/run/${dhcpService}/leases --dhcp-option=3,10.${toString cfg.networkOctet}.0.1 --dhcp-option=6,10.${toString cfg.networkOctet}.0.1 ${lib.concatStringsSep " " (lib.imap0 (i: _: "--dhcp-host=${mac i},${ip i}") taps)}";
          RuntimeDirectory = dhcpService;
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
    };
  scaleSets = lib.mapAttrs scaleSetModule active;
  controllerModule = name: controller:
    let
      unitName = serviceName name;
      names = if name == "default" then lib.attrNames grouped else [ name ];
      sets = map (setName: scaleSets.${setName}) names;
      dependencies = lib.concatMap (set: [ "${set.networkService}.service" "${set.dhcpService}.service" ]) sets ++ [ "nftables.service" ];
      runDir = "/run/${unitName}";
      multiple = builtins.length names > 1;
      rendered = lib.genAttrs names (setName:
        let set = scaleSets.${setName}; in
        if set.imageConfigFile == null then set.runtimeConfig
        else if multiple then "${runDir}/${setName}.json"
        else "${runDir}/config.json");
      configPath = if multiple then "${runDir}/config.json" else rendered.${name};
    in
    {
      assertions = [
        { assertion = lib.hasPrefix "/" controller.privateKeyFile && !(lib.hasPrefix builtins.storeDir controller.privateKeyFile); message = "actions-vm-scaler privateKeyFile must be an absolute runtime secret path outside the Nix store."; }
      ];
      users.groups.${unitName} = { };
      users.users.${unitName} = {
        isSystemUser = true;
        group = unitName;
        extraGroups = [ "kvm" ];
      };
      systemd.services.${unitName} = {
        unitConfig.RequiresMountsFor = lib.concatMap (set: lib.optional (set.imageConfigFile != null) set.imageConfigFile) sets ++ map stateDir names;
        preStart = lib.mkIf (multiple || controller.imageConfigFile != null) (
          lib.concatMapStringsSep "\n"
            (setName:
              let set = scaleSets.${setName}; in
              lib.optionalString (set.imageConfigFile != null) ''
                ${pkgs.jq}/bin/jq -s '.[0] as $base | $base + {vm: (.[1] * $base.vm)}' \
                  ${set.runtimeConfig} ${lib.escapeShellArg set.imageConfigFile} > ${rendered.${setName}}
              '')
            names + lib.optionalString multiple ''
            ${pkgs.jq}/bin/jq -s . ${lib.concatMapStringsSep " " (setName: toString rendered.${setName}) names} > ${configPath}
          ''
        );
        description = "GitHub Actions VM scaler (${lib.concatStringsSep ", " names})";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        requires = dependencies;
        after = [ "network-online.target" ] ++ dependencies;
        serviceConfig = {
          Type = "simple";
          User = unitName;
          Group = unitName;
          SupplementaryGroups = [ "kvm" ];
          ExecStart = "${package}/bin/actions-vm-scaler run ${configPath}";
          RuntimeDirectory = unitName;
          RuntimeDirectoryMode = "0700";
          LoadCredential = [ "github-app-key:${controller.privateKeyFile}" ];
          StateDirectory = map serviceName names;
          StateDirectoryMode = "0700";
          UMask = "0077";
          Restart = "on-failure";
          RestartSec = 30;
          TimeoutStopSec = 40;
          KillMode = "mixed";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          RestrictSUIDSGID = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
          DevicePolicy = "closed";
          DeviceAllow = [ "/dev/kvm rw" "/dev/net/tun rw" ];
          LimitCORE = 0;
        };
      };
      programs.adminCommands.commands.${unitName} = [ "${package}/bin/actions-vm-scaler" ];
    };
  controllers = lib.mapAttrs controllerModule (lib.optionalAttrs cfg.enable { default = cfg; } // activeInstances);
  modules = lib.attrValues scaleSets ++ lib.attrValues controllers;
in
{
  imports = [ ../modules/admin-commands.nix ];
  options.services.actions-vm-scaler = instanceOptions // {
    enable = lib.mkEnableOption "disposable QEMU GitHub Actions runners";
    instances = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule {
        options = instanceOptions // { enable = lib.mkEnableOption "this additional VM scale set"; };
      });
      description = "Additional independently capped scale sets; reserve distinct networks and synthetic NIC slot ranges.";
    };
    scaleSets = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule { options = scaleSetOptions; });
      description = "Additional scale sets served by the default controller, sharing its GitHub App and repository discovery. Each needs distinct capacity slots and a distinct network.";
    };
  };
  config = lib.genAttrs [ "users" "networking" "systemd" "programs" ]
    (key: lib.mkMerge (map (module: module.${key} or { }) modules)) // {
    boot.kernel.sysctl = lib.mkIf (active != { }) { "net.ipv4.ip_forward" = 1; };
    assertions = [
      { assertion = builtins.length (lib.unique macSlots) == builtins.length macSlots; message = "Actions VM scaler instances must reserve disjoint synthetic NIC slots."; }
      { assertion = !(cfg.instances ? default || cfg.scaleSets ? default); message = "The default scaler name is reserved."; }
      { assertion = cfg.enable || cfg.scaleSets == { }; message = "Additional scale sets require the default scaler to be enabled."; }
      { assertion = lib.intersectAttrs cfg.instances cfg.scaleSets == { }; message = "Scaler instance and scale set names must be distinct."; }
      {
        assertion = builtins.length (lib.unique (map (i: i.networkOctet) (lib.attrValues active))) == builtins.length (lib.attrValues active);
        message = "Actions VM scaler instances must use distinct networks.";
      }
    ] ++ lib.concatMap (module: module.assertions) modules;
  };
}
