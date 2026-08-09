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

  installPacmanAutoUpdate = pkgs.writeShellApplication {
    name = "install-pacman-auto-update";
    runtimeInputs = [ pkgs.coreutils pkgs.systemd ];
    text = ''
      if (( EUID != 0 )); then
        exec /usr/bin/sudo "$0" "$@"
      fi

      install -Dm0644 ${pacmanService} \
        /etc/systemd/system/pacman-auto-update.service
      install -Dm0644 ${pacmanTimer} \
        /etc/systemd/system/pacman-auto-update.timer

      systemctl daemon-reload
      systemctl enable --now pacman-auto-update.timer
      systemctl status --no-pager pacman-auto-update.timer
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
  home.packages = [ installPacmanAutoUpdate ];

  home.activation.pacmanAutoUpdate = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if ! /usr/bin/systemctl is-enabled --quiet pacman-auto-update.timer 2>/dev/null; then
      warnEcho "The pacman auto-update system timer is not installed."
      warnEcho "Run: install-pacman-auto-update"
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
