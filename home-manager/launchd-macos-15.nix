{ lib, ... }:
{
  # The pinned Home Manager 26.05 module unconditionally uses bootout --wait,
  # which only exists on macOS 26+. Preserve its activation DAG and replace
  # that invocation with the older bootout followed by a short unload delay.
  options.home.activation = lib.mkOption {
    apply = entries: lib.mapAttrs
      (name: entry:
        if name == "setupLaunchAgents" then entry // {
          data = lib.replaceStrings
            [ ''run /bin/launchctl bootout --wait "$domain/$agentName"'' ]
            [ ''{ run /bin/launchctl bootout "$domain/$agentName" && run sleep 1; }'' ]
            entry.data;
        } else entry)
      entries;
  };
}
