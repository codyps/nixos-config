# A second OpenCode server, running entirely inside the crow-ai container.
#
# The host server (services.opencode in configuration.nix) stays untouched,
# including its optional per-project sandbox plugin. This server runs in
# the guest as cody-ai, so everything it does happens inside the container
# by construction. Cody's plugins from /home/cody/.config/opencode/plugins
# are bind-mounted read-only at /run/opencode-plugins and listed in
# cody-ai's own editable user config, seeded below; nothing plugin-related
# is baked into the managed /etc settings, and the sandbox plugin is not
# loaded here. It listens on the private
# container link at 10.80.0.2:49375 and is exposed as
# https://crow.little-moth.ts.net:8444 through a Tailscale Serve relay on
# the host. Tailnet clients can also reach http://10.80.0.2:49375
# directly via the advertised 10.80.0.2/32 route. The password is the
# same opencode-password secret as the host server.
#
# sops-nix renders root-owned symlinks that crow-ai's user namespace
# cannot read, and rotation swaps them out from under a bind mount, so
# crow-ai-opencode-secrets.service stages stable regular files owned by
# the container-mapped cody-ai account and binds that directory into the
# guest read-only (the runtime launcher id-maps this mount). Rotating
# either secret restages the files and restarts the in-container daemon;
# the host relay needs no restart.
#
# The guest has no tailscaled, so MagicDNS names such as the Strata
# backend are unresolvable through its LAN DNS: the guest sends
# little-moth.ts.net queries to Crow's resolver (listening on 10.80.0.1
# on the private link) and routes 100.64.0.0/10 through Crow. Return
# traffic rides the advertised 10.80.0.2/32 route, so no NAT is involved.
{ config, lib, pkgs, ... }:

let
  # cody-ai (1001) and its group (993) translated into crow-ai's
  # host-side user-namespace range, for staging secrets the guest can read.
  aiUid = toString (config.containers.crow-ai.privateUsers + 1001);
  aiGid = toString (config.containers.crow-ai.privateUsers + 993);
  # Guest copy of cody's plugin list (see /home/cody/.config/opencode/
  # opencode.json on Crow), with paths rebased to the read-only /run mount
  # below. Seeded into cody-ai's home once and never overwritten, so the
  # list stays editable inside the container.
  userConfig = pkgs.writeText "opencode-user-config.json" (builtins.toJSON {
    "$schema" = "https://opencode.ai/config.json";
    plugins = [
      "/run/opencode-plugins/pareto-cost"
      {
        package = "/run/opencode-plugins/zai-plan-cost";
        options = {
          monthlyPrice = 64;
          weeklyCredits = 60000;
        };
      }
      "/run/opencode-plugins/peak-hours"
      "/run/opencode-plugins/zai-quota"
    ];
  });
in
{
  systemd.services.crow-ai-opencode-secrets = {
    description = "Stage OpenCode secrets for the crow-ai container";
    wantedBy = [ "multi-user.target" ];
    requires = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
    # The nspawn bind mount fails when the staged directory is missing.
    before = [ "container@crow-ai.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    script = ''
      ${pkgs.coreutils}/bin/install -d -m 0700 /var/lib/crow-ai
      ${pkgs.coreutils}/bin/install -d -m 0700 -o ${aiUid} -g ${aiGid} /var/lib/crow-ai/opencode-secrets
      ${pkgs.coreutils}/bin/install -m 0400 -o ${aiUid} -g ${aiGid} \
        ${config.sops.secrets.opencode-password.path} /var/lib/crow-ai/opencode-secrets/opencode-password
      ${pkgs.coreutils}/bin/install -m 0400 -o ${aiUid} -g ${aiGid} \
        ${config.sops.secrets.strata-api-key.path} /var/lib/crow-ai/opencode-secrets/strata-api-key
      # The daemon loads its password credential and provider key at start;
      # rotate a live container's server after restaging the files.
      if ${pkgs.systemd}/bin/systemctl is-active --quiet container@crow-ai.service; then
        ${pkgs.systemd}/bin/systemctl --machine=crow-ai try-restart opencode-server.service || true
      fi
    '';
  };

  containers.crow-ai.bindMounts."/run/opencode-secrets" = {
    hostPath = "/var/lib/crow-ai/opencode-secrets";
    isReadOnly = true;
  };

  # Live plugin sources, shared with the host server's user config: edits
  # as cody on Crow apply after restarting the guest daemon. Like the
  # secrets mount, this is part of the container's bind mount boundary.
  containers.crow-ai.bindMounts."/run/opencode-plugins" = {
    hostPath = "/home/cody/.config/opencode/plugins";
    isReadOnly = true;
  };

  containers.crow-ai.config = {
    imports = [ ../../nixos-modules/opencode.nix ];
    services.opencode = {
      enable = true;
      settings = {
        "$schema" = "https://opencode.ai/config.json";
        providers.strata = {
          name = "Strata (local)";
          package = "@opencode/ai/providers/openai-compatible";
          settings = {
            baseURL = "http://desktop-lgmeaa4.little-moth.ts.net:8080/v1";
            apiKey = "{file:/run/opencode-secrets/strata-api-key}";
          };
          models."qwen3.8-flash-next-iq3_s" = {
            name = "Qwen3.8-Flash-Next (local)";
            capabilities = {
              tools = true;
              input = [ "text" "image" ];
              output = [ "text" ];
              reasoning.supported = true;
            };
            compatibility.reasoningField = "reasoning_content";
            limit = {
              context = 131072;
              input = 114688;
              output = 16384;
            };
          };
        };
      };
      server = {
        enable = true;
        user = "cody-ai";
        hostname = "10.80.0.2";
        passwordFile = "/run/opencode-secrets/opencode-password";
      };
    };
    # Seed cody-ai's editable OpenCode user config (the plugin list) once;
    # activation never overwrites it afterwards. Mirrors the codex-config
    # seeding pattern, including runuser's users/etc dependencies.
    system.activationScripts.seedOpencodeUserConfig = {
      deps = [ "users" "etc" ];
      text = ''
        if [ ! -e /home/cody-ai/.config/opencode/opencode.json ]; then
          ${pkgs.util-linux}/bin/runuser -u cody-ai -- \
            ${pkgs.coreutils}/bin/install -D -m 0644 \
            ${userConfig} /home/cody-ai/.config/opencode/opencode.json
        fi
      '';
    };
    # Reach tailnet CGNAT addresses (including the Strata backend)
    # through Crow; the resolver below handles MagicDNS names.
    systemd.network.networks."10-ai".routes = [
      { Gateway = "10.80.0.1"; Destination = "100.64.0.0/10"; }
    ];
    # MagicDNS names are not publicly resolvable and the guest has no
    # tailscaled; route tailnet-name queries to Crow's resolver, which
    # answers on the private link. All other names use LAN DNS directly.
    services.resolved.settings.Resolve = {
      DNS = "10.80.0.1";
      Domains = "~little-moth.ts.net";
    };
    # Wi-Fi may be absent while Ethernet is up; any one routable uplink
    # satisfies network-online consumers such as opencode-server.
    systemd.network.wait-online.anyInterface = true;
  };

  # Answer the guest's tailnet-name queries on the private link.
  services.resolved.settings.Resolve.DNSStubListenerExtra = "10.80.0.1:53";
  networking.firewall.interfaces."ve-crow-ai" = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };
  # Forward between the container's private link and the tailnet: the
  # in-container OpenCode server reaches the Strata backend, and tailnet
  # clients reach the advertised 10.80.0.2/32 route. Tailnet peers do not
  # universally accept subnet routes, so guest traffic leaving for the
  # tailnet is masqueraded as crow itself; replies then return reliably.
  networking.nat = {
    enable = true;
    externalInterface = "tailscale0";
    internalInterfaces = [ "ve-crow-ai" ];
  };

  # HTTPS relay for the in-container server. The host server keeps 8443.
  systemd.services.opencode-container-tailscale-https = {
    description = "Expose the crow-ai OpenCode server over Tailscale HTTPS";
    wantedBy = [ "multi-user.target" ];
    wants = [ "tailscaled.service" "container@crow-ai.service" ];
    after = [ "tailscaled.service" "container@crow-ai.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 10;
      ExecStart = "${pkgs.tailscale}/bin/tailscale serve --bg --https=8444 http://10.80.0.2:49375";
      ExecStop = "${pkgs.tailscale}/bin/tailscale serve --https=8444 off";
    };
  };
}
