{ config, pkgs, ... }:

let
  cache-home =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "Library/Caches"
    else
      ".cache"
  ;
in
{
  programs.atuin = {
    enable = true;
    flags = [ "--disable-up-arrow" ];
  };

  home.file.".config/atuin/config.toml".source = ../config/.config/atuin/config.toml;

  systemd.user.services.atuind = {
    Service = {
      # TODO: consider removing unix socket, it existing causes issues
      ExecStartPre = "${pkgs.coreutils}/bin/rm -f %h/.local/share/atuin/atuin.sock";
      ExecStart = "${pkgs.atuin}/bin/atuin daemon";
      Environment = "ATUIN_LOG=info";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
    Unit = {
      After = [ "network.target" ];
      X-Restart-Triggers = [
        "${pkgs.atuin}"
        "${config.home.file.".config/atuin/config.toml".source}"
      ];
    };
  };

  launchd.agents = {
    atuin-daemon = {
      enable = true;
      config = {
        #ProgramArguments = [ "${pkgs.atuin}/bin/atuin" "daemon" ];
        ProgramArguments =
          let
            atuin-daemon = pkgs.writeShellScriptBin "atuin-daemon" ''
              mkdir -p ${config.home.homeDirectory}/${cache-home}/atuin;
              # A stale socket left behind by an unclean shutdown makes the
              # daemon crash-loop with "Address already in use" (launchd
              # guarantees a single instance, so removal is safe here).
              rm -f ${config.home.homeDirectory}/.local/share/atuin/atuin.sock;
              # exec so atuin gets launchd's SIGTERM directly and can clean up
              # its socket, instead of dying as an orphan when the shell exits.
              exec ${pkgs.atuin}/bin/atuin daemon;
            '';
          in
          [ "${atuin-daemon}/bin/atuin-daemon" ];
        EnvironmentVariables.ATUIN_LOG = "info";
        StandardErrorPath = "${config.home.homeDirectory}/${cache-home}/atuin/atuin-daemon-error.log";
        StandardOutPath = "${config.home.homeDirectory}/${cache-home}/atuin/atuin-daemon-out.log";
        RunAtLoad = true;
        KeepAlive = true;
      };
    };
  };
}
