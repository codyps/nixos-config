{ lib, pkgs }:
let
  # Explicit personal machines and login accounts; no domain-wide wildcards.
  linuxHosts = {
    adams = "x";
    arch1 = "cody";
    arnold = "cody";
    calvin = "y";
    constance = "cody2";
    crow = "cody";
    finch = "cody";
    findley = "nixos";
    forbes = "cody";
    mifflin = "cody";
    penguin = "cody";
    robin = "cody";
    warbler = "cody";
    ward = "cody";
  };
  darwinHosts = {
    u3 = "cody";
    wren = "cody";
    x-mbp = "x";
  };
  prepareAgent = pkgs.writeShellScript "gpg-agent-forwarding-source" ''
    set -eu
    ${pkgs.gnupg}/bin/gpgconf --launch gpg-agent
    socket=$(${pkgs.gnupg}/bin/gpgconf --list-dirs agent-extra-socket)
    test -S "$socket"
    ${pkgs.coreutils}/bin/mkdir -p -m 700 "$HOME/.gnupg"
    ${pkgs.coreutils}/bin/ln -sfn -- "$socket" "$HOME/.gnupg/S.gpg-agent.forward-extra"
  '';
  sourceSocket = "%d/.gnupg/S.gpg-agent.forward-extra";
  hostNames = host: lib.concatStringsSep "," [
    host
    "${host}.local"
    "${host}.bed.einic.org"
    "${host}.little-moth.ts.net"
  ];
  stanza = socket: host: user: ''
    Match host ${hostNames host} user ${user} localuser cody,cody2,x,y,nixos exec "test '%L' != '${host}' && ${prepareAgent}"
      RemoteForward ${socket} ${sourceSocket}
      RemoteForward ${socket}.extra ${sourceSocket}
  '';
in
''
  # GPG's restricted extra socket keeps private keys and pinentry on the source.
  ${lib.concatStrings (lib.mapAttrsToList (stanza "/run/user/1000/gnupg/S.gpg-agent") linuxHosts)}
  ${lib.concatStrings (lib.mapAttrsToList (host: user: stanza "/Users/${user}/.gnupg/S.gpg-agent" host user) darwinHosts)}
  Match all
''
