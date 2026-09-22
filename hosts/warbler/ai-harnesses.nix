{ config, lib, pkgs, ... }:
let
  user = "cody-ai";
  home = "/home/${user}";
  # The pinned Nixpkgs does not yet package Vite+'s global CLI. Use the
  # upstream GNU release and patch its loader for NixOS.
  vitePlus = pkgs.stdenvNoCC.mkDerivation rec {
    pname = "vite-plus";
    version = "0.3.3";
    src = pkgs.fetchurl {
      url = "https://github.com/voidzero-dev/vite-plus/releases/download/v${version}/vp-x86_64-unknown-linux-gnu.tar.gz";
      hash = "sha256-Cs804xgtIPJFtY+wpMYRMpsED2TZ0rdrkbvZB7yfxPg=";
    };
    sourceRoot = ".";
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin" "$out/libexec/vite-plus"
      cp -r vp toolchain.json sync-versions "$out/libexec/vite-plus/"
      ln -s "$out/libexec/vite-plus/vp" "$out/bin/vp"
      runHook postInstall
    '';
    meta = {
      homepage = "https://viteplus.dev/";
      license = lib.licenses.mit;
      platforms = [ "x86_64-linux" ];
      mainProgram = "vp";
    };
  };
  codingTools = with pkgs; [ git gh gcc rustup mbx nodejs bun uv pnpm vitePlus python3 ripgrep jq ];
  localBinPaths = map (path: "${home}/${path}") [
    ".local/share/python-default/bin"
    ".local/bin"
    ".cargo/bin"
    ".npm-global/bin"
    ".bun/bin"
    ".local/share/pnpm"
    ".local/share/vite-plus/bin"
    ".vite-plus/bin"
    ".yarn/bin"
    ".config/yarn/global/node_modules/.bin"
    "go/bin"
    ".deno/bin"
    ".dotnet/tools"
    ".gem/bin"
    ".nix-profile/bin"
    ".local/state/nix/profile/bin"
  ];
  codingEnvironment = {
    NPM_CONFIG_PREFIX = "${home}/.npm-global";
    GEM_HOME = "${home}/.gem";
    BUN_INSTALL = "${home}/.bun";
    PNPM_HOME = "${home}/.local/share/pnpm";
  };
  # A writable default venv supports plain pip installs without changing the
  # Nix-managed interpreter. Project venvs can still override it normally.
  shellEnvironment = pkgs.writeText "ai-coding-environment" ''
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") codingEnvironment)}
    export PATH=${lib.escapeShellArg (lib.concatStringsSep ":" localBinPaths)}:"$PATH"
    if [ ! -x ${home}/.local/share/python-default/bin/python ]; then
      ${pkgs.python3}/bin/python3 -m venv ${home}/.local/share/python-default
    fi
  '';
  socket = "${home}/.codex/app-server-control/app-server-control.sock";
  inherit (import ../../nixos/ssh-auth.nix) authorizedKeys;
  # Optional compatibility for clients that launch a JSON-lines app server.
  # Native daemon discovery and proxying do not need this adapter.
  transportPython = pkgs.python3.withPackages (p: [ p.websockets ]);
  supervisor = pkgs.writeShellScript "codex-ai-service" (''
    set -e
    source ${shellEnvironment}
  '' + builtins.readFile ./codex-service.sh);
  codexRemote = pkgs.writeShellScriptBin "codex" ''
    export CODEX_HOME=${home}/.codex
    current="$CODEX_HOME/packages/standalone/current"
    codex="$current/bin/codex"
    if [ ! -x "$codex" ]; then codex="$current/codex"; fi
    if [ ! -x "$codex" ]; then
      echo 'Codex has not been installed by codex-ai.service yet.' >&2
      exit 1
    fi
    if [ "''${1-}" = remote-control ] && [ "''${2-}" != pair ]; then
      echo 'Remote control runs in codex-ai.service; use codex remote-control pair to pair a phone.' >&2
      exit 1
    fi
    if [ "''${1-}" = app-server ]; then
      shift
      if [ "''${1-}" = daemon ]; then
        case "''${2-}" in
          start|version)
            # Probe only: even a stale socket must not cause a detached launch
            # outside systemd's sandbox.
            if [ ! -S ${socket} ]; then
              echo 'codex-ai.service is not ready; contact the administrator.' >&2
              exit 1
            fi
            exec "$codex" app-server daemon version
            ;;
        esac
        echo 'Codex lifecycle is managed by codex-ai.service.' >&2
        exit 1
      fi
      if [ "''${1-}" = proxy ]; then
        exec "$codex" app-server proxy --sock ${socket}
      fi
      ${lib.optionalString (!config.services.codex-ai.stdioForwarder.enable) ''
        echo 'Custom stdio forwarding is disabled; use the native app-server proxy.' >&2
        exit 1
      ''}
      ${lib.optionalString config.services.codex-ai.stdioForwarder.enable ''
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --stdio|--analytics-default-enabled) shift ;;
          --listen)
            [ "''${2-}" = stdio:// ] || exit 2
            shift 2
            ;;
          *)
            echo "Unsupported managed app-server argument: $1" >&2
            exit 2
            ;;
        esac
      done
      exec ${transportPython}/bin/python3 ${./codex-stdio.py} ${socket}
      ''}
    fi
    exec "$codex" "$@"
  '';
in
{
  options.services.codex-ai.stdioForwarder.enable = lib.mkEnableOption
    "the custom JSON-lines stdio compatibility adapter for Codex";

  config = {
    # Vite+ downloads Node runtimes during first-use setup. Their standard
    # ELF interpreter must be available even though this host uses Nix paths.
    programs.nix-ld.enable = true;

    users.groups.${user} = { };
    users.users.${user} = {
      isNormalUser = true;
      description = "Cody's isolated AI harness account";
      group = user;
      extraGroups = [ ];
      inherit home;
      homeMode = "0700";
      hashedPassword = "!";
      shell = pkgs.bashInteractive;
      packages = [ codexRemote ] ++ codingTools;
      openssh.authorizedKeys.keys = map (key: "restrict,pty ${key}") authorizedKeys;
    };

    # Also enforce permissions on an existing home; /home is already persistent.
    users.users.cody.homeMode = "0700";
    systemd.tmpfiles.rules = [
      "d ${home} 0700 ${user} ${user} -"
      "d ${home}/workspaces 0700 ${user} ${user} -"
      "d ${home}/.codex 0700 ${user} ${user} -"
      "z /home/cody 0700 cody users -"
    ];

    services.openssh.extraConfig = ''
      Match User ${user}
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        DisableForwarding yes
        PermitUserRC no
      Match all
    '';
    # Neither sudo nor a desktop policy agent should confer host privileges.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (subject.user == "${user}") return polkit.Result.NO;
      });
    '';
    # Daemon builds use Nix's build sandbox, outside the service mount sandbox.
    # allowed-users grants ordinary daemon access, not trusted-user privileges.
    nix.settings.allowed-users = lib.mkForce [ "root" "cody" user "nix-ssh" "@wheel" ];
    environment.etc."bashrc.local".text = ''
      if [ "$(id -un)" = ${user} ]; then
        source ${shellEnvironment}
      fi
    '';

    systemd.services.codex-ai = {
      description = "Codex app server for Cody's AI harness account";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
      unitConfig.RequiresMountsFor = [ home ];
      path = with pkgs; [ bashInteractive coreutils procps curl cacert gnutar gzip gnugrep gnused gawk findutils openssh config.nix.package ] ++ codingTools;
      environment = codingEnvironment // {
        HOME = home;
        CODEX_HOME = "${home}/.codex";
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      };
      serviceConfig = {
        Type = "simple";
        User = user;
        Group = user;
        WorkingDirectory = "${home}/workspaces";
        ExecStart = supervisor;
        KillMode = "control-group";
        TimeoutStopSec = 30;
        Restart = "always";
        RestartSec = 30;
        UMask = "0077";
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        BindPaths = [ home ];
        ReadWritePaths = [ home ];
        InaccessiblePaths = [ "-/persist" "-/run/secrets" "-/run/user" "-/run/dbus" "-/run/systemd/private" ];
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        SystemCallArchitectures = "native";
        TasksMax = "infinity";
        # User namespaces remain available for Codex's own Linux sandbox.
      };
    };

    assertions = [{
      assertion = config.users.users.${user}.extraGroups == [ ];
      message = "The AI harness account must not have supplementary groups.";
    }];
  };
}
