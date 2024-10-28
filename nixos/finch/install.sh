#! /usr/bin/env bash
set -x
nixos-install -I nixos-config=/mnt/persist/etc/nixos/configuration.nix --no-root-password
