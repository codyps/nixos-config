#! /usr/bin/env bash
set -euf -o pipefail

pia_token_load() {
	echo "loading token"
	if ! [ -e "$DATA_DIR/token" ]; then
		return 1
	fi

	PIA_TOKEN="$(jq -r .token "$DATA_DIR/token")"
}

pia_token_refresh() {
	echo "refreshing token"
	generateToken="$(curl -s -u "$PIA_USERNAME:$PIA_PASSWORD" \
		"https://privateinternetaccess.com/gtoken/generateToken")"

	if [ "$(echo "$generateToken" | jq -r '.status')" != "OK" ]; then
		>&2 echo "generateToken failed: $generateToken"
		return
	fi

	echo "$generateToken" >"$DATA_DIR/token"
	PIA_TOKEN="$(jq -r .token "$DATA_DIR/token")"
}

pia_token() {
	pia_token_load && return
	pia_token_refresh
}

pia_list_countries() {
	pia_token
	pia_servers="$(curl --max-time 15 'https://serverlist.piaservers.net/vpninfo/servers/v6' | head -1)"
	echo "$pia_servers" | jq
}

pia_add_key_fetch() {
	wireguard_json="$(curl -G \
	  --connect-to "$WG_HOSTNAME::$WG_SERVER_IP:" \
	  --cacert "$DATA_DIR/cacert" \
	  --data-urlencode "pt=${PIA_TOKEN}" \
	  --data-urlencode "pubkey=$WG_PUBKEY" \
	  "https://${WG_HOSTNAME}:1337/addKey" )"
}

pia_add_key() {
	pia_token
	pia_add_key_fetch
	if [ "$(echo "$wireguard_json" | jq -r '.status')" == "OK" ]; then
		return 0
	fi

	echo "addKey failed: $wireguard_json"

	pia_token_refresh
	pia_add_key_fetch
	if [ "$(echo "$wireguard_json" | jq -r '.status')" == "OK" ]; then
		return 0
	fi

	echo "addKey failed (2): $wireguard_json"
	return 1
}

pia_pick_server() {
	echo "picking server"

	pia_servers_resp="$(curl --max-time 15 'https://serverlist.piaservers.net/vpninfo/servers/v6') | head -1)"
	pia_servers="$(echo "$pia_servers_resp" | head -1)"

	echo "got servers"

	# remote ips
	country_json="$(printf "%s" "$pia_servers" | jq --arg network_id "$NETWORK_ID" '.regions[] | select (.id == $network_id)')"
	servers_json="$(printf "%s" "$country_json" | jq '.servers.wg')"
	server_ct="$(printf "%s" "$servers_json" | jq length)"
	server_n="$(shuf -i 0-"$((server_ct-1))" -n 1)"

	server_json="$(printf "%s" "$servers_json" | jq --argjson server_n "$server_n" '.[$server_n]')"

	echo "$server_json" >"$DATA_DIR/server"

	WG_SERVER_IP=$(printf "%s" "$server_json" | jq -r .ip)
	WG_HOSTNAME=$(printf "%s" "$server_json" | jq -r .cn)

	echo "got server for network_id=$NETWORK_ID"
}

pia_server_load() {
	if ! [ -e "$DATA_DIR/server" ]; then
		return 1
	fi

	echo "loading existing server"

	server_json="$(cat "$DATA_DIR/server")"
	WG_SERVER_IP=$(printf "%s" "$server_json" | jq -r .ip)
	WG_HOSTNAME=$(printf "%s" "$server_json" | jq -r .cn)
}

pia_server() {
	pia_server_load || pia_pick_server
}

pia_renew() {
	pia_server
	pia_add_key || {
		echo "addKey failed, retrying with new server"
		pia_pick_server
		pia_add_key
	}

	echo "addKey success"

	WG_SERVER_PORT="$(echo "$wireguard_json" | jq -r .server_port)"
	# ip of server over the vpn.
	WG_SERVER_VIP="$(echo "$wireguard_json" | jq -r .server_vip)"

	WG_ADDR="$(echo "$wireguard_json" | jq -r .peer_ip)"
	WG_SERVER_PUBKEY="$(echo "$wireguard_json" | jq -r .server_key)"
	WG_SERVER_ENDPOINT="$WG_SERVER_IP:$WG_SERVER_PORT"

	WG_SERVER_DNS="$(echo "$wireguard_json" | jq -r '.dns_servers[0]')"
}

pia_payload_and_signature_load() {
	echo "loading payload and signature"

	if ! [ -e "$DATA_DIR/payload_and_signature" ]; then
		>&2 echo "payload_and_signature file not found"
		return 1
	fi

	payload_and_signature="$(cat "$DATA_DIR/payload_and_signature")"
	if [ "$(echo "$payload_and_signature" | jq -r '.status')" != "OK" ]; then
		>&2 echo "payload_and_signature content not ok: $payload_and_signature"
		return 1
	fi
	payload=$(echo "$payload_and_signature" | jq -r '.payload')
	expires_at=$(echo "$payload" | base64 -d | jq -r '.expires_at')
	if [ "$(date -d "$expires_at" +%s)" -lt "$(date +%s)" ]; then
		echo "port forward expired"
		return 1
	fi
}

pia_payload_and_signature_refresh_fetch() {
	echo "refreshing payload and signature"

	payload_and_signature="$(ip netns exec "$NETNS_NAME" \
		curl -s -m 5 \
		--connect-to "$WG_HOSTNAME::$WG_SERVER_VIP:" \
		--cacert "$DATA_DIR/cacert" \
		-G --data-urlencode "token=${PIA_TOKEN}" \
		"https://${WG_HOSTNAME}:19999/getSignature")"

	if [ "$(echo "$payload_and_signature" | jq -r '.status')" != "OK" ];then
		>&2 echo "getSignature failed: $payload_and_signature"
		unset payload_and_signature
		return 1
	fi

	echo "$payload_and_signature" >"$DATA_DIR/payload_and_signature"
}

pia_payload_and_signature_refresh() {
	if pia_payload_and_signature_refresh_fetch; then
		echo "refreshed payload and signature successfully (first try)"
		return 0
	fi

	echo "refreshing payload and signature (retry with new token)"
	pia_token_refresh
	pia_payload_and_signature_refresh_fetch
}

pia_payload_and_signature() {
	echo "getting payload and signature"
	if pia_payload_and_signature_load; then
		return 0
	fi

	echo "load failed, refreshing payload and signature"
	pia_token
	pia_payload_and_signature_refresh
}

pia_port_forward_bind() {
	signature=$(echo "$payload_and_signature" | jq -r '.signature')
	payload=$(echo "$payload_and_signature" | jq -r '.payload')
	expires_at=$(echo "$payload" | base64 -d | jq -r '.expires_at')
	port=$(echo "$payload" | base64 -d | jq -r '.port')

	bind_port_response="$(ip netns exec "$NETNS_NAME" \
		curl -Gs -m 5 \
		--connect-to "$WG_HOSTNAME::$WG_SERVER_VIP:" \
		--cacert "$DATA_DIR/cacert" \
		--data-urlencode "payload=${payload}" \
		--data-urlencode "signature=${signature}" \
		"https://${WG_HOSTNAME}:19999/bindPort")"

	if [[ $(echo "$bind_port_response" | jq -r '.status') != "OK" ]]; then
		>&2 echo "bindPort failed: $bind_port_response"
		return 1
	fi

	echo "port forward success, port=$port"

	echo "$port" >"$DATA_DIR/port"
}

pia_port_forward() {
	pia_payload_and_signature
	if pia_port_forward_bind; then
		return 0
	fi

	echo "port forward failed, refreshing payload and signature"
	pia_payload_and_signature_refresh || {
		echo "refresh failed"
		return 1
	}

	if pia_port_forward_bind; then
		return 0
	fi

	echo "port forward failed"
	return 1
}

DATA_DIR="$1"
NETNS_NAME="$2"
NETWORK_ID="$3"

WIREGUARD_NAME="wg-$NETNS_NAME"

NETNS_DIR="/etc/netns/$NETNS_NAME"

umask 0077

if ! [ -e "$DATA_DIR/private_key" ]; then
	wg genkey >"$DATA_DIR/private_key"
fi

if ! [ -e "$DATA_DIR/cacert" ]; then
	cat <<EOF >"$DATA_DIR/cacert"
-----BEGIN CERTIFICATE-----
MIIHqzCCBZOgAwIBAgIJAJ0u+vODZJntMA0GCSqGSIb3DQEBDQUAMIHoMQswCQYD
VQQGEwJVUzELMAkGA1UECBMCQ0ExEzARBgNVBAcTCkxvc0FuZ2VsZXMxIDAeBgNV
BAoTF1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMSAwHgYDVQQLExdQcml2YXRlIElu
dGVybmV0IEFjY2VzczEgMB4GA1UEAxMXUHJpdmF0ZSBJbnRlcm5ldCBBY2Nlc3Mx
IDAeBgNVBCkTF1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMS8wLQYJKoZIhvcNAQkB
FiBzZWN1cmVAcHJpdmF0ZWludGVybmV0YWNjZXNzLmNvbTAeFw0xNDA0MTcxNzQw
MzNaFw0zNDA0MTIxNzQwMzNaMIHoMQswCQYDVQQGEwJVUzELMAkGA1UECBMCQ0Ex
EzARBgNVBAcTCkxvc0FuZ2VsZXMxIDAeBgNVBAoTF1ByaXZhdGUgSW50ZXJuZXQg
QWNjZXNzMSAwHgYDVQQLExdQcml2YXRlIEludGVybmV0IEFjY2VzczEgMB4GA1UE
AxMXUHJpdmF0ZSBJbnRlcm5ldCBBY2Nlc3MxIDAeBgNVBCkTF1ByaXZhdGUgSW50
ZXJuZXQgQWNjZXNzMS8wLQYJKoZIhvcNAQkBFiBzZWN1cmVAcHJpdmF0ZWludGVy
bmV0YWNjZXNzLmNvbTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALVk
hjumaqBbL8aSgj6xbX1QPTfTd1qHsAZd2B97m8Vw31c/2yQgZNf5qZY0+jOIHULN
De4R9TIvyBEbvnAg/OkPw8n/+ScgYOeH876VUXzjLDBnDb8DLr/+w9oVsuDeFJ9K
V2UFM1OYX0SnkHnrYAN2QLF98ESK4NCSU01h5zkcgmQ+qKSfA9Ny0/UpsKPBFqsQ
25NvjDWFhCpeqCHKUJ4Be27CDbSl7lAkBuHMPHJs8f8xPgAbHRXZOxVCpayZ2SND
fCwsnGWpWFoMGvdMbygngCn6jA/W1VSFOlRlfLuuGe7QFfDwA0jaLCxuWt/BgZyl
p7tAzYKR8lnWmtUCPm4+BtjyVDYtDCiGBD9Z4P13RFWvJHw5aapx/5W/CuvVyI7p
Kwvc2IT+KPxCUhH1XI8ca5RN3C9NoPJJf6qpg4g0rJH3aaWkoMRrYvQ+5PXXYUzj
tRHImghRGd/ydERYoAZXuGSbPkm9Y/p2X8unLcW+F0xpJD98+ZI+tzSsI99Zs5wi
jSUGYr9/j18KHFTMQ8n+1jauc5bCCegN27dPeKXNSZ5riXFL2XX6BkY68y58UaNz
meGMiUL9BOV1iV+PMb7B7PYs7oFLjAhh0EdyvfHkrh/ZV9BEhtFa7yXp8XR0J6vz
1YV9R6DYJmLjOEbhU8N0gc3tZm4Qz39lIIG6w3FDAgMBAAGjggFUMIIBUDAdBgNV
HQ4EFgQUrsRtyWJftjpdRM0+925Y6Cl08SUwggEfBgNVHSMEggEWMIIBEoAUrsRt
yWJftjpdRM0+925Y6Cl08SWhge6kgeswgegxCzAJBgNVBAYTAlVTMQswCQYDVQQI
EwJDQTETMBEGA1UEBxMKTG9zQW5nZWxlczEgMB4GA1UEChMXUHJpdmF0ZSBJbnRl
cm5ldCBBY2Nlc3MxIDAeBgNVBAsTF1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMSAw
HgYDVQQDExdQcml2YXRlIEludGVybmV0IEFjY2VzczEgMB4GA1UEKRMXUHJpdmF0
ZSBJbnRlcm5ldCBBY2Nlc3MxLzAtBgkqhkiG9w0BCQEWIHNlY3VyZUBwcml2YXRl
aW50ZXJuZXRhY2Nlc3MuY29tggkAnS7684Nkme0wDAYDVR0TBAUwAwEB/zANBgkq
hkiG9w0BAQ0FAAOCAgEAJsfhsPk3r8kLXLxY+v+vHzbr4ufNtqnL9/1Uuf8NrsCt
pXAoyZ0YqfbkWx3NHTZ7OE9ZRhdMP/RqHQE1p4N4Sa1nZKhTKasV6KhHDqSCt/dv
Em89xWm2MVA7nyzQxVlHa9AkcBaemcXEiyT19XdpiXOP4Vhs+J1R5m8zQOxZlV1G
tF9vsXmJqWZpOVPmZ8f35BCsYPvv4yMewnrtAC8PFEK/bOPeYcKN50bol22QYaZu
LfpkHfNiFTnfMh8sl/ablPyNY7DUNiP5DRcMdIwmfGQxR5WEQoHL3yPJ42LkB5zs
6jIm26DGNXfwura/mi105+ENH1CaROtRYwkiHb08U6qLXXJz80mWJkT90nr8Asj3
5xN2cUppg74nG3YVav/38P48T56hG1NHbYF5uOCske19F6wi9maUoto/3vEr0rnX
JUp2KODmKdvBI7co245lHBABWikk8VfejQSlCtDBXn644ZMtAdoxKNfR2WTFVEwJ
iyd1Fzx0yujuiXDROLhISLQDRjVVAvawrAtLZWYK31bY7KlezPlQnl/D9Asxe85l
8jO5+0LdJ6VyOs/Hd4w52alDW/MFySDZSfQHMTIc30hLBJ8OnCEIvluVQQ2UQvoW
+no177N9L2Y+M9TcTA62ZyMXShHQGeh20rb4kK8f+iFX8NxtdHVSkxMEFSfDDyQ=
-----END CERTIFICATE-----
EOF
fi

WG_PRIVKEY="$(cat "$DATA_DIR/private_key")"
WG_PUBKEY="$(wg pubkey <"$DATA_DIR/private_key")"

port_forward_time=0

while true; do
	pia_renew "$WG_PUBKEY" "$NETWORK_ID"

	wg_sync_conf=""
	trap 'rm -f "$wg_sync_conf"' EXIT
	wg_sync_conf="$(mktemp -t pia-wg-util."$NETNS_NAME".XXXXXX)"

	# XXX: do we need to set the listen port?
	cat <<-EOF >"$wg_sync_conf"
	[Interface]
	PrivateKey = $WG_PRIVKEY

	[Peer]
	PersistentKeepalive = 25
	PublicKey = $WG_SERVER_PUBKEY
	AllowedIPs = 0.0.0.0/0
	Endpoint = $WG_SERVER_ENDPOINT
	EOF

	echo "nameserver $WG_SERVER_DNS" >"$NETNS_DIR/resolv.conf"

	ip netns exec "$NETNS_NAME" wg syncconf "$WIREGUARD_NAME" "$wg_sync_conf"
	ip -n "$NETNS_NAME" link set dev "$WIREGUARD_NAME" up
	ip -n "$NETNS_NAME" addr flush dev "$WIREGUARD_NAME"
	ip -n "$NETNS_NAME" addr add dev "$WIREGUARD_NAME" "$WG_ADDR"
	ip -n "$NETNS_NAME" route add default dev "$WIREGUARD_NAME"

	echo "wireguard up"

	pia_port_forward && {
		port_forward_time="$(date +%s)"
	} || echo "port forward failed"

	while true; do
		echo "sleeping until ping check"
		sleep 60s
		ping -q -c1 8.8.8.8 || {
			echo "ping failed"
			break
		}

		# refresh port forward every 15 minutes
		if [ "$((port_forward_time + 900))" -lt "$(date +%s)" ]; then
			pia_port_forward && {
				port_forward_time="$(date +%s)"
			} || echo "port forward failed"
		fi
	done
done
