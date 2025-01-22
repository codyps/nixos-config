#! /usr/bin/env nix-shell
#! nix-shell -i bash -p ipcalc iproute2 gawk

set -euf -o pipefail
tailscale_if="$1"
tailscale_table=52

ip addr | grep '^    inet' | awk '{print $2}' | while read -r ip; do
	a="$(ipcalc -n --no-decorate "$ip")"
	b="$(ipcalc -p --no-decorate "$ip")"
	subnet="$a/$b"
	if ip route show table "$tailscale_table" | grep -q "$subnet dev $tailscale_if"; then
		echo "Removing unwanted route to $subnet..."
		ip route del "$subnet" dev "$tailscale_if" table "$tailscale_table" && \
			echo "Route successfully removed!"
	fi
done

# fixme: race, we need to start monitoring before we do our initial scan.
ip monitor route | while read -r line; do
    ip addr | grep '^    inet' | awk '{print $2}' | while read -r ip; do
        a="$(ipcalc -n --no-decorate "$ip")"
        b="$(ipcalc -p --no-decorate "$ip")"
        subnet="$a/$b"
        if echo "$line" | grep -q "^$subnet dev $tailscale_if"; then
            if ip route show table "$tailscale_table" | grep -q "$subnet dev $tailscale_if"; then
                echo "Removing unwanted route to $subnet..."
                ip route del "$subnet" dev "$tailscale_if" table "$tailscale_table" && \
                echo "Route successfully removed!"
            fi
        fi
    done
done
