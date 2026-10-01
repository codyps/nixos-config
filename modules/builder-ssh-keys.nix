# Shared client keys accepted by the managed remote Nix builders.
(import ../nixos/ssh-auth.nix).authorizedKeys ++ [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA2gAJB7HLffugJejcMpcSUa64q176A6vpdPLI/fBLp/ root@u3"
]
