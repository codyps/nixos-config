# ZPL preview proxy

Warbler runs the `codyps/zpl` NixOS module pinned by `flake.lock`. The socket
listens on TCP 3000, with firewall access on the wired LAN and Tailscale.
Open `http://warbler:3000/`; `GET /api/printers` lists `ZD621` and `ZQ610-Plus`.
Submit JSON containing `zpl` to `POST /api/printers/{name}/preview` for a PNG.
This service renders previews using the printers; it does not print labels.

The complete printer map (HTTP origins, SGD control addresses, serial pins,
canvas sizes, and optional HTTP headers) is encrypted in
`zpl-printers.enc.json` for the admin PGP key and warbler's age host identity.
The initial map uses the previously validated native canvases: 832 × 240 dots
for ZD621 and 384 × 2030 dots for ZQ610-Plus. Update these defaults in the secret
if the intended preview canvas changes.

To edit with an authorized SOPS identity:

```sh
sops hosts/warbler/zpl-printers.enc.json
```

This is a SOPS binary document containing a JSON object keyed by public printer
name. Keep decrypted files outside the checkout and Nix store. sops-nix installs
it root-only at `/run/secrets/zpl-printers`; systemd passes a private copy through
`LoadCredential`. Secret updates restart the worker on activation.

The upstream module confines the worker and manages
`/var/lib/zpl-proxy-api/db.sqlite`. Warbler already persists `/var/lib` across
root resets. The database contains submitted ZPL, rendered images, and request
and recovery history. The worker starts on the first socket connection.

```sh
nix run .#nixos-rebuild-remote -- warbler switch
ssh cody@warbler systemctl status zpl-proxy-api.socket zpl-proxy-api.service
ssh cody@warbler sudo journalctl -u zpl-proxy-api.service -n 30
curl http://warbler:3000/api/printers
```

The API has no application authentication. Access is limited by the host
firewall to the LAN and tailnet; no public reverse proxy is configured.
