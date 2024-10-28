#! /usr/bin/env bash

ip addr add dev enX0 207.90.192.55/24
ip route add default via 207.90.192.1
echo "nameserver 8.8.8.8" | resolvconf -a enX0
