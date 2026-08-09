{ config, lib, pkgs, ... }:

let
  flakeDirectory = "${config.home.homeDirectory}/dev/nixos-config";

  pacmanService = pkgs.writeText "pacman-auto-update.service" ''
    [Unit]
    Description=Automatically update Arch Linux packages
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=oneshot
    ExecStart=/usr/bin/pacman -Syu --noconfirm
  '';

  pacmanTimer = pkgs.writeText "pacman-auto-update.timer" ''
    [Unit]
    Description=Weekly Arch Linux package update

    [Timer]
    OnCalendar=weekly
    Persistent=true
    RandomizedDelaySec=2h

    [Install]
    WantedBy=timers.target
  '';

  nixService = pkgs.writeText "nix-auto-update.service" ''
    [Unit]
    Description=Automatically update the system-wide Nix installation
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=oneshot
    ExecStart=/nix/var/nix/profiles/default/bin/nix upgrade-nix --profile /nix/var/nix/profiles/default
    ExecStartPost=/usr/bin/systemctl daemon-reload
    ExecStartPost=/usr/bin/systemctl try-restart nix-daemon.service
  '';

  nixTimer = pkgs.writeText "nix-auto-update.timer" ''
    [Unit]
    Description=Weekly system-wide Nix update

    [Timer]
    OnCalendar=weekly
    Persistent=true
    RandomizedDelaySec=2h

    [Install]
    WantedBy=timers.target
  '';

  installSystemAutoUpdates = pkgs.writeShellApplication {
    name = "install-system-auto-updates";
    runtimeInputs = [ pkgs.coreutils pkgs.systemd ];
    text = ''
      if (( EUID != 0 )); then
        exec /usr/bin/sudo "$0" "$@"
      fi

      install -Dm0644 ${pacmanService} \
        /etc/systemd/system/pacman-auto-update.service
      install -Dm0644 ${pacmanTimer} \
        /etc/systemd/system/pacman-auto-update.timer
      install -Dm0644 ${nixService} \
        /etc/systemd/system/nix-auto-update.service
      install -Dm0644 ${nixTimer} \
        /etc/systemd/system/nix-auto-update.timer

      systemctl daemon-reload
      systemctl enable --now pacman-auto-update.timer nix-auto-update.timer
      systemctl status --no-pager pacman-auto-update.timer nix-auto-update.timer
    '';
  };

  homeManagerUpdate = pkgs.writeShellScript "home-manager-auto-update" ''
    set -eu

    exec ${pkgs.util-linux}/bin/flock --nonblock \
      "${config.xdg.cacheHome}/home-manager-auto-update.lock" \
      ${pkgs.bash}/bin/bash -c '
        set -eu
        ${pkgs.nix}/bin/nix flake update --flake ${flakeDirectory}
        ${config.programs.home-manager.path}/bin/home-manager switch \
          --flake ${flakeDirectory}#cody@arch1
      '
  '';

  timer = {
    OnCalendar = "weekly";
    Persistent = true;
    RandomizedDelaySec = "2h";
  };
in
{
  home.packages = [ installSystemAutoUpdates ];

  home.activation.systemAutoUpdates = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if ! ${pkgs.diffutils}/bin/cmp --silent ${pacmanService} \
        /etc/systemd/system/pacman-auto-update.service \
      || ! ${pkgs.diffutils}/bin/cmp --silent ${pacmanTimer} \
        /etc/systemd/system/pacman-auto-update.timer \
      || ! ${pkgs.diffutils}/bin/cmp --silent ${nixService} \
        /etc/systemd/system/nix-auto-update.service \
      || ! ${pkgs.diffutils}/bin/cmp --silent ${nixTimer} \
        /etc/systemd/system/nix-auto-update.timer \
      || ! /usr/bin/systemctl is-enabled --quiet pacman-auto-update.timer 2>/dev/null \
      || ! /usr/bin/systemctl is-enabled --quiet nix-auto-update.timer 2>/dev/null; then
      warnEcho "The pacman and Nix auto-update system units are missing, outdated, or disabled."
      warnEcho "Run: install-system-auto-updates"
    fi
  '';

  systemd.user.services.home-manager-auto-update = {
    Unit = {
      Description = "Automatically update and activate Home Manager";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = homeManagerUpdate;
    };
  };

  systemd.user.timers.home-manager-auto-update = {
    Unit.Description = "Weekly Home Manager update";
    Timer = timer;
    Install.WantedBy = [ "timers.target" ];
  };
}
