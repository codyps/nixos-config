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
  aiBubblewrap = pkgs.callPackage ./ai-bubblewrap.nix { };
  codingTools = with pkgs; [ git gh gcc aiBubblewrap bazelisk (writeShellScriptBin "bazel" ''exec ${bazelisk}/bin/bazelisk "$@"'') rustup mbx nodejs bun uv pnpm vitePlus python3 ripgrep jq ];
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
  # The login shell itself enters the sandbox: sshd invokes ForceCommand via
  # this shell, so no user-controlled Bash startup file runs on the host.
  # Privileged Bash mode ignores BASH_ENV and imported shell functions.
  sshSandbox = (pkgs.writeScriptBin "ai-sandbox-shell" ''
    #!${pkgs.bash}/bin/bash -p
    set -euo pipefail
    if [ "''${1-}" = -c ] && [ "''${2-}" = ai-sandbox-session ]; then
      if [ -n "''${SSH_ORIGINAL_COMMAND-}" ]; then
        set -- -c "$SSH_ORIGINAL_COMMAND"
      else
        set --
      fi
    fi
    # internal-sftp must run as an external server inside the mount namespace.
    if [ "''${1-}" = -c ] && [ "''${2-}" = internal-sftp ]; then
      set -- -c ${pkgs.openssh}/libexec/sftp-server
    fi
    exec ${pkgs.bubblewrap}/bin/bwrap \
      --unshare-user --unshare-pid --unshare-ipc --unshare-uts \
      --die-with-parent --new-session --cap-drop ALL \
      --ro-bind /nix/store /nix/store \
      --ro-bind /run/current-system /run/current-system \
      --ro-bind /etc/profiles/per-user/${user} /etc/profiles/per-user/${user} \
      --ro-bind /nix/var/nix/profiles /nix/var/nix/profiles \
      --ro-bind /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket \
      ${lib.concatMapStringsSep " \\\n      " (path: "--ro-bind-try ${path} ${path}") [
        "/etc/passwd" "/etc/group" "/etc/nsswitch.conf" "/etc/hosts"
        "/etc/resolv.conf" "/etc/localtime" "/etc/profile" "/etc/bashrc"
        "/etc/bashrc.local" "/etc/inputrc" "/etc/nix" "/etc/ssl/certs"
        "/etc/termcap" "/etc/terminfo"
      ]} \
      --dir /bin --symlink ${pkgs.bash}/bin/bash /bin/sh \
      --dir /usr/bin --symlink ${pkgs.coreutils}/bin/env /usr/bin/env \
      --proc /proc --dev /dev --tmpfs /tmp --tmpfs /var/tmp \
      --bind ${home} ${home} --chdir "$PWD" \
      --unsetenv BASH_ENV --unsetenv ENV \
      --setenv SHELL ${pkgs.bashInteractive}/bin/bash \
      --setenv HOME ${home} \
      --setenv PATH /etc/profiles/per-user/${user}/bin:/run/current-system/sw/bin \
      -- ${pkgs.bashInteractive}/bin/bash -l "$@"
  '').overrideAttrs (old: {
    passthru = (old.passthru or { }) // { shellPath = "/bin/ai-sandbox-shell"; };
  });
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
            # The SSH PID namespace cannot see the service's daemon PID.
            # Native daemon discovery treats that PID as stale and deletes
            # its state, so probe the explicit socket without discovery.
            ${pkgs.python3}/bin/python3 -c 'import socket; s = socket.socket(socket.AF_UNIX); s.connect("${socket}"); s.close()' || exit 1
            echo 'Codex app server is running (control socket reachable).'
            if [ "''${2-}" = version ]; then
              printf 'Installed CLI: '
              "$codex" --version
            fi
            exit 0
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
  imports = [ ../../nixos-modules/codex-config.nix ];

  options.services.codex-ai.stdioForwarder.enable = lib.mkEnableOption
    "the custom JSON-lines stdio compatibility adapter for Codex";

  config = {
    programs.codex-config.users = [ user ];
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
      shell = sshSandbox;
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
        ForceCommand ai-sandbox-session
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
        # Bubblewrap uses NETLINK_ROUTE to configure loopback in nested sandboxes.
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
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
