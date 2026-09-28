"""Generate host-local controller keys once, outside the Nix store."""
import json
import os
from pathlib import Path
import secrets
import sys

os.umask(0o077)
keys = Path("/var/lib/garm/keys.json")
if not keys.exists():
    with keys.open("x") as stream:
        json.dump({"jwt": secrets.token_hex(32), "database": secrets.token_hex(16)}, stream)
data = json.loads(keys.read_text())
template = Path(sys.argv[1]).read_text()
Path("/run/garm/config.toml").write_text(
    template.replace("@JWT_SECRET@", data["jwt"]).replace("@DATABASE_KEY@", data["database"])
)
