# Hindsight memory server

Warbler imports `hindsight.nix`. It runs the upstream Hindsight 0.10.2 image,
pinned by OCI manifest digest, under Podman. Only the API, built-in MCP server,
and background worker run; the bundled web control plane is not exposed.

## Access

After activation and provider setup:

| Client location | REST base URL | MCP URL for the shared bank |
| --- | --- | --- |
| Tailscale | `http://warbler.little-moth.ts.net:8888` | `http://warbler.little-moth.ts.net:8888/mcp/shared/` |
| warbler-ai | `http://10.79.0.1:8888` | `http://10.79.0.1:8888/mcp/shared/` |
| Warbler host | `http://127.0.0.1:8888` | `http://127.0.0.1:8888/mcp/shared/` |

REST and MCP both require `Authorization: Bearer <api-key>`. The shared key is
decrypted by SOPS to `/run/secrets/hindsight-api-key`; retrieve it only through
an authorized root session into the client's private credential store. Never
paste it into chat, commit it, or embed it in a URL. The key grants access to
all banks in this single-user deployment.

Tailscale encrypts traffic between machines. The private AI link stays on the
host. A dedicated nftables chain blocks port 8888 on every other interface,
even if that interface is otherwise trusted. No LAN or public listener is
permitted through the firewall. PostgreSQL listens only on host loopback.

Use bank ID `shared` consistently across clients, and attach project, client,
session, and timestamp metadata. Client installation and automatic session
capture are separate work; this configuration does not install agent plugins,
ingest historical conversations, or create the bank before first startup.

## Extraction provider: OpenAI API

The service stays stopped until `/var/lib/hindsight/provider.env` exists.
Provision this root-owned, mode-0600 file through SOPS once the provider key
location is supplied. Its parent is created mode 0700. The API/database keys are already
generated and encrypted in `hindsight-secrets.json` for Warbler and Cody.

OpenAI API example (replace the placeholder securely, never in Nix):

```dotenv
HINDSIGHT_API_LLM_API_KEY=<provision-with-sops>
```

The module selects OpenAI and `gpt-5.4-mini` for extraction. To change to
local inference later, choose a supported OpenAI-compatible provider and supply
`HINDSIGHT_API_LLM_BASE_URL`, the served model name, and any required API key.
An inference service on another host must be reachable from Warbler. No GPU
inference server is installed by this module.

Hindsight also documents `openai-codex` authentication. That requires a
dedicated authenticated Codex directory and a container mount, which are not
configured here. Do not reuse warbler-ai's active refresh-token files.

Embeddings (`BAAI/bge-small-en-v1.5`) and the default local reranker use CPU in
the full upstream image. Model traces and Hugging Face telemetry are disabled.
The inference provider may still receive the memory content it processes.

## Persistence and operations

PostgreSQL 17 owns database `hindsight` with `vector` and `pg_trgm` extensions.
`hindsight-database.service` sets the database role password from a systemd
credential before the API starts. Secrets are rendered at runtime, outside the
Nix store. The worker ID is fixed to `warbler-hindsight` across restarts.

Data lives in `/var/lib/postgresql/17`, persisted under Warbler's encrypted
`/persist`. Daily PostgreSQL backups go to `/var/lib/postgresql-backups`, also
persisted under `/persist`. These are local recovery copies, not off-host backups.
Copy backups off the machine for host-loss protection. Treat them as private
conversation data. Snapshot or back up the database before changing the image
digest: application migrations can make a binary downgrade insufficient.

Standard administration:

```sh
systemctl status podman-hindsight hindsight-database postgresql
journalctl -u podman-hindsight -n 100
systemctl status postgresqlBackup-hindsight
```

The first start pulls the pinned full image from GHCR (several GB). A successful
NixOS build validates the system configuration but does not pull or run that
image. Once provider settings are available and warbler-ai is confirmed done,
activate and check unauthenticated REST/MCP rejection, authenticated bank
creation, retention, and recall. Then restart the API and verify the stored
memory survives. Also verify blocked LAN access and allowed Tailscale/private
AI-link access before connecting all clients.

No activation or container restart is authorized while warbler-ai is working.
The setup-time process check still showed agent sessions; an idle-looking
process alone does not establish that the work is complete.

References: [installation](https://hindsight.vectorize.io/developer/installation),
[configuration](https://hindsight.vectorize.io/developer/configuration),
[MCP](https://hindsight.vectorize.io/developer/mcp-server).
