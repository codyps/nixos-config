{ lib, pkgs, ... }:
let
  user = "cody-ai";
  home = "/home/${user}";
  inherit (import ../../nixos/ssh-auth.nix) authorizedKeys;
  localPaths = map (path: "${home}/${path}") [
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
  networking.hostName = "warbler-ai";
  imports = [ ../../nixos-modules/codex-config.nix ];
  programs.codex-config.users = [ user ];
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
      (codingEnvironment // { PATH = toolPath; }));
  systemd.tmpfiles.rules = [
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
    wantedBy = [ "default.target" ];
    after = [ "ai-python.service" ];
    unitConfig.ConditionUser = user;
    environment = codingEnvironment;
    serviceConfig = {
      ExecStart = supervisor;
      WorkingDirectory = home;
      Restart = "always";
      RestartSec = 30;
      KillMode = "control-group";
      TimeoutStopSec = 30;
      UMask = "0077";
      TasksMax = "infinity";
    };
  };
  # The container is the common boundary. Do not hide its own user manager or
  # create separate mount/PID namespaces for agent tasks and SSH sessions.
  systemd.user.settings.Manager.DefaultTasksMax = "infinity";
}
