{ config, lib, pkgs, ... }:
{
  authorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILO6B2Cx3SVmD65J9sJsmxhjZq/AGprzpRMcrqbCuu6Y cody@u3.bed.einic.org"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINzOdeXt93UUseJFVdCdTysB+2xZN/Ig+jNGHjP8o8jZ cody@peyton"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBuIFt7UdC7wzmcO6tK06fkPpY6sCI8z7mtPBfLm2Xjq nixos@findley"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINtGDM0k7iyhZGaxyiS+Rn1tXbfOh1oK3nQAiCMx+ZzE cody@mifflin"
  ];

  nix.sshServe.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA2gAJB7HLffugJejcMpcSUa64q176A6vpdPLI/fBLp/ root@u3"
  ] ++ authorizedKeys;
}
