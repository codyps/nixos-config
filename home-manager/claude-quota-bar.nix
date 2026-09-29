{ config, pkgs, ... }:
{
  home.packages = [ pkgs.claude-quota-bar ];

  launchd.agents.claude-quota-bar = {
    enable = true;
    # Start through a launcher named claude-quota-bar rather than the default
    # /bin/sh wait4path wrapper, so Login Items shows a readable name. If
    # launchd starts it before the store is mounted, KeepAlive retries it.
    waitForNixStore = false;
    config = {
      ProgramArguments = [ "${pkgs.claude-quota-bar}/Applications/Claude Quota Bar.app/Contents/MacOS/claude-quota-bar" ];
      RunAtLoad = true;
      # Restart after a crash, but let Quit in the menu stay quit until next login.
      KeepAlive.SuccessfulExit = false;
      LimitLoadToSessionType = "Aqua";
      ProcessType = "Interactive";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/claude-quota-bar.log";
    };
  };
}
