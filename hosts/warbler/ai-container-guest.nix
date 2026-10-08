{ config, lib, pkgs, ... }:
let
  user = "cody-ai";
  home = "/home/${user}";
  inherit (import ../../nixos/ssh-auth.nix) authorizedKeys;
  mbxShimDirectory = "${home}/.local/share/mbx/bin";
  cargoShim = import ../../nixpkgs/mbx-cargo-shim.nix { inherit pkgs; };
  mbxTarget = pkgs.writeText "mbx-target" "${pkgs.mbx}/bin/mbx\n";
  localPaths = map (path: "${home}/${path}") [
    ".local/share/mbx/bin"
    ".local/bin"
    ".local/share/python-default/bin"
    ".cargo/bin"
    ".npm-global/bin"
    ".bun/bin"
    ".local/share/pnpm"
    ".vite-plus/bin"
    ".local/share/vite-plus/bin"
    "go/bin"
    ".deno/bin"
    ".dotnet/tools"
    ".nix-profile/bin"
    ".local/state/nix/profile/bin"
  ];
  toolPath = lib.concatStringsSep ":" (localPaths ++ [
    "/etc/profiles/per-user/${user}/bin"
    "/run/current-system/sw/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  ]);
  codingEnvironment = {
    # nspawn assembles /sys from bind mounts. perf's mount autodetection picks
    # /sys/block as the root otherwise, hiding all hardware/software events.
    SYSFS_PATH = "/sys";
    NPM_CONFIG_PREFIX = "${home}/.npm-global";
    BUN_INSTALL = "${home}/.bun";
    PNPM_HOME = "${home}/.local/share/pnpm";
    CODEX_HOME = "${home}/.codex";
    HERMES_HOME = "${home}/.hermes";
  };
  codex = pkgs.writeShellScriptBin "codex" ''
    export CODEX_HOME=${home}/.codex
    current="$CODEX_HOME/packages/standalone/current"
    if [ -x "$current/bin/codex" ]; then
      exec "$current/bin/codex" "$@"
    elif [ -x "$current/codex" ]; then
      exec "$current/codex" "$@"
    fi
    echo 'Codex is installing; check journalctl --user -u codex-ai.' >&2
    exit 1
  '';
  supervisor = pkgs.writeShellScript "ai-container-codex" (''
    export PATH=${lib.escapeShellArg toolPath}
    mkdir -p ${home}/workspaces
  '' + builtins.readFile ./codex-service.sh);
  updateCodex = pkgs.writeShellScript "ai-container-codex-update" (''
    export PATH=${lib.escapeShellArg toolPath}
  '' + builtins.readFile ./codex-update.sh);
  installHermes = pkgs.writeShellApplication {
    name = "install-hermes";
    runtimeInputs = [ pkgs.curl pkgs.bash ];
    text = ''
      installer=$(mktemp)
      trap 'rm -f "$installer"' EXIT
      curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        https://hermes-agent.nousresearch.com/install.sh -o "$installer"
      bash "$installer" "$@"
    '';
  };
in
{
  programs.adminCommands.commands.install-hermes = [ "${installHermes}/bin/install-hermes" ];
  programs.adminCommands.commands.update-codex = [ "${pkgs.systemd}/bin/systemctl" "--user" "start" "codex-ai-update.service" ];
  programs.adminCommands.commands.restart-codex = [ "${pkgs.systemd}/bin/systemctl" "--user" "reload" "codex-ai.service" ];
  networking.hostName = "warbler-ai";
  imports = [ ../../modules/terminfo.nix ./ai-user-config.nix ./ai-git.nix ./ai-rust.nix ../../nixos-modules/git-gh-credentials.nix ];
  system.stateVersion = "26.05";
  time.timeZone = "America/New_York";
  documentation.enable = false;
  networking.useHostResolvConf = false;
  networking.useDHCP = false;
  systemd.network = {
    enable = true;
    networks."10-lan" = {
      matchConfig.Name = "mv-eno1";
      linkConfig.MACAddress = "02:57:41:52:41:49";
      networkConfig = { DHCP = "yes"; IPv6AcceptRA = true; };
      dhcpV4Config = { ClientIdentifier = "mac"; SendHostname = true; };
    };
  };
  services.resolved.enable = true;
  services.avahi = {
    enable = true;
    publish.enable = true;
    publish.addresses = true;
    openFirewall = true;
  };
  networking.firewall.enable = true;
  services.openssh = {
    enable = true;
    startWhenNeeded = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ user ];
    };
  };

  users.groups.${user}.gid = 993;
  users.users.${user} = {
    isNormalUser = true;
    uid = 1001;
    group = user;
    inherit home;
    homeMode = "0700";
    hashedPassword = "!";
    shell = pkgs.bashInteractive;
    linger = true;
    openssh.authorizedKeys.keys = authorizedKeys;
  };
  security.sudo.enable = false;
  services.dbus.enable = true;
  programs.nix-ld.enable = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # Containers do not inherit nixosSystem's nixpkgs registry/NIX_PATH pin.
  # Make both nix-shell -p and nixpkgs# references use our existing sources.
  nixpkgs.flake.source = builtins.path { path = pkgs.path; name = "source"; };
  # Legacy shells should resolve locally without fetching the flake registry.
  nix.settings.nix-path = [ "nixpkgs=${config.nixpkgs.flake.source}" ];

  programs.atuin = {
    enable = true;
    enableBashIntegration = true;
    flags = [ "--disable-up-arrow" ];
    daemon.enable = true;
    settings = lib.recursiveUpdate
      (builtins.fromTOML (builtins.readFile ../../config/.config/atuin/config.toml))
      {
        daemon = {
          systemd_socket = true;
          socket_path = "$XDG_RUNTIME_DIR/atuin/atuin.sock";
        };
      };
  };
  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    nix-direnv.enable = true;
    direnvrcExtra = lib.mkAfter ''
      # Restore Cargo shim priority after a development shell changes PATH.
      _mbx_direnv_exit() {
        local status=$?
        local shim=${lib.escapeShellArg mbxShimDirectory}
        if [[ -x "$shim/cargo" && ":$PATH:" == *":$shim:"* ]]; then
          PATH_add "$shim"
        fi
        "$direnv" dump json "" >&3
        trap - EXIT
        exit "$status"
      }
      trap _mbx_direnv_exit EXIT
    '';
  };

  environment.systemPackages = (with pkgs; [
    bashInteractive
    coreutils
    curl
    wget
    git
    gh
    gcc
    gnumake
    cmake
    (pkgs.callPackage ./ai-bubblewrap.nix { })
    bazelisk
    (writeShellScriptBin "bazel" ''exec ${bazelisk}/bin/bazelisk "$@"'')
    pkg-config
    rustup
    mbx
    nodejs
    bun
    uv
    pnpm
    python3
    (lib.lowPrio python311)
    ripgrep
    jq
    ffmpeg-headless
    xz
    unzip
    zip
    file
    which
    procps
    # CPU, heap, syscall, and process/I/O profiling for AI development tasks.
    perf
    valgrind
    heaptrack
    gdb
    strace
    sysstat
    htop
    smem
    time
    hyperfine
    flamegraph
    findutils
    gnugrep
    gnused
    gawk
    gnutar
    gzip
    openssh
    tmux
    neovim
  ]) ++ [ codex installHermes ];
  environment.sessionVariables = codingEnvironment;
  environment.extraInit = ''
    export PATH=${lib.escapeShellArg toolPath}:"$PATH"
  '';
  # User services (including Hermes-generated units) must work without a login.
  environment.etc."environment.d/60-ai.conf".text =
    lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value: "${name}=${value}")
      (codingEnvironment // {
        PATH = toolPath;
        inherit (config.environment.variables) ATUIN_CONFIG_DIR DIRENV_CONFIG;
      }));
  systemd.tmpfiles.rules = [
    "d ${home}/.local 0755 ${user} ${user} -"
    "d ${home}/.local/share 0755 ${user} ${user} -"
    "d ${home}/.local/share/mbx 0755 ${user} ${user} -"
    "d ${home}/.local/share/mbx/bin 0755 ${user} ${user} -"
    "L+ ${mbxShimDirectory}/cargo - ${user} ${user} - ${cargoShim}"
    "L+ ${mbxShimDirectory}/mbx-target - ${user} ${user} - ${mbxTarget}"
    "d ${home}/workspaces 0700 ${user} ${user} -"
    "d ${home}/.codex 0700 ${user} ${user} -"
    # Hermes-generated units may omit the Nix profile from their PATH.
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin"
    "L+ /bin/bash - - - - ${pkgs.bashInteractive}/bin/bash"
    "L+ /bin/kill - - - - ${pkgs.coreutils}/bin/kill"
  ] ++ map (command: "L+ /usr/bin/${command} - - - - /run/current-system/sw/bin/${command}") [
    "bash"
    "python"
    "python3"
    "node"
    "git"
    "curl"
    "systemctl"
    "loginctl"
  ];
  systemd.user.services.ai-python = {
    description = "Writable default Python environment";
    wantedBy = [ "default.target" ];
    before = [ "codex-ai.service" ];
    unitConfig.ConditionUser = user;
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      if [ ! -x ${home}/.local/share/python-default/bin/python ]; then
        ${pkgs.python3}/bin/python3 -m venv ${home}/.local/share/python-default
      fi
    '';
  };
  systemd.user.services.codex-ai = {
    description = "Self-managed Codex in the AI container";
    # A switch must not terminate the daemon's active turns. Lifecycle updates
    # are handled by Codex; supervisor changes take effect at the next start.
    restartIfChanged = false;
    wantedBy = [ "default.target" ];
    after = [ "ai-python.service" ];
    unitConfig.ConditionUser = user;
    environment = codingEnvironment;
    serviceConfig = {
      ExecStart = "${supervisor} foreground";
      # SIGHUP is Codex's graceful-only drain: repeated requests never force
      # termination. New turns are rejected while existing turns finish.
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      WorkingDirectory = home;
      Restart = "always";
      RestartSec = 2;
      KillMode = "mixed";
      KillSignal = "SIGHUP";
      TimeoutStopSec = "infinity";
      UMask = "0077";
      TasksMax = "infinity";
    };
  };
  systemd.user.services.codex-ai-update = {
    description = "Update Codex packages and request a graceful drain";
    unitConfig.ConditionUser = user;
    environment = codingEnvironment;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = updateCodex;
      UMask = "0077";
      TimeoutStartSec = "30min";
    };
  };
  systemd.user.timers.codex-ai-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnStartupSec = "5min";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "2min";
    };
  };
  # The container is the common boundary. Do not hide its own user manager or
  # create separate mount/PID namespaces for agent tasks and SSH sessions.
  systemd.user.settings.Manager.DefaultTasksMax = "infinity";
}
