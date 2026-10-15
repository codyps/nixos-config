# GPG agent forwarding between personal hosts

SSH connections between the personal machines listed in
`lib/gpg-agent-forwarding.nix` forward the originating machine's restricted GPG
extra socket. Signing and decryption use that machine's private keys and
pinentry. Public keys must also be present in the destination's keyring.
The SSH helper starts the source agent and discovers its extra socket with
`gpgconf`, including when a custom `GNUPGHOME` is set.

The rules match explicit short names, `.local`, `.bed.einic.org` and
`.little-moth.ts.net` names, together with each machine's personal login account.
They exclude work machines, AI accounts, root, unrelated hosts and connections
back to the originating machine. They do not enable SSH agent forwarding.

The standard and extra sockets are both forwarded, so a connection from u3 to
Warbler and then from Warbler to Ward can continue using u3's agent. Linux
destinations use the primary personal account's UID 1000 socket directory;
Darwin destinations use their configured `/Users/USER/.gnupg` directory. Update
the mapping if an account's UID or GnuPG home changes.

## Activation and use

Rebuild the source and destination systems to install the client and server
settings. Standalone Home Manager configurations install the client rules;
their SSH server must separately permit Unix socket forwarding and set
`StreamLocalBindUnlink yes`. Initialize GnuPG once on a new destination with
`gpgconf --create-socketdir` so its socket directory exists.

Start a new SSH connection after activation. An existing multiplexed connection
may need to be closed with `ssh -O exit HOST` first. Then use ordinary commands:

```sh
ssh cody@warbler
printf 'forwarding check\n' | gpg --no-autostart --armor --detach-sign
```

Pinentry should appear on the originating machine. This also covers Git's GPG
commit signing and SOPS decryption. It does not make keys available to an
already running service with a separate GnuPG home or sandbox.

One originating agent controls a destination account's sockets at a time.
Connecting from another source replaces that account's forwarding. To return
to a Linux destination's own agent after disconnecting, restore its systemd
sockets if necessary:

```sh
systemctl --user stop gpg-agent.service
systemctl --user restart gpg-agent.socket gpg-agent-extra.socket
gpgconf --launch gpg-agent
```

Private keys remain on the source. Connected destination accounts can request
signatures or decryption while forwarding is active. See the
[GnuPG extra-socket documentation](https://www.gnupg.org/documentation/manuals/gnupg/Agent-Options.html#index-extra_002dsocket)
and [OpenSSH socket forwarding options](https://man.openbsd.org/ssh_config#RemoteForward).
