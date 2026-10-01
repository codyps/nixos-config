{ config, lib, ... }:
let
  cfg = config.services.remote-nix-builder;
in
{
  options.services.remote-nix-builder = {
    enable = lib.mkEnableOption "SSH access to the Nix daemon for remote builds";
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Public keys allowed to submit remote builds; these clients are trusted Nix users.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.authorizedKeys != [ ];
      message = "Remote Nix builder access requires at least one authorized key.";
    }];

    services.openssh.enable = true;
    users.knownUsers = [ "nix-ssh" ];
    users.users.nix-ssh = {
      uid = 450;
      description = "Remote Nix builder";
      isHidden = true;
      home = "/var/empty";
      shell = "/bin/sh";
    };
    nix.settings.trusted-users = [ "nix-ssh" ];

    # Root-owned keys cannot be replaced by the service account.
    environment.etc."nix/builder-authorized-keys".text =
      lib.concatMapStringsSep "\n" (key: "restrict ${key}") cfg.authorizedKeys + "\n";
    services.openssh.extraConfig = ''
      Match User nix-ssh
        AuthorizedKeysFile /etc/nix/builder-authorized-keys
        AuthenticationMethods publickey
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        AllowTcpForwarding no
        AllowAgentForwarding no
        X11Forwarding no
        PermitTTY no
        PermitUserRC no
        ForceCommand ${config.nix.package}/bin/nix-daemon --stdio
      Match all
    '';
  };
}
