#!/usr/bin/env python3
"""Check real JSSE default anchors against compatible and AUX-bearing bundles."""

import base64
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile


def fingerprints(bundle):
    return {
        hashlib.sha256(base64.b64decode(block)).hexdigest()
        for block in re.findall(
            rb"-----BEGIN CERTIFICATE-----\s+(.*?)-----END CERTIFICATE-----",
            Path(bundle).read_bytes(), re.S,
        )
    }


Path("TestJavaTrustStore.java").write_bytes(Path(os.environ["JAVA_TEST_SOURCE"]).read_bytes())
subprocess.run(["javac", "TestJavaTrustStore.java"], check=True)
expected = fingerprints(os.environ["CA_BUNDLE"])
extra = fingerprints(os.environ["EXTRA_CA"])
assert len(expected) > 80
assert not expected & extra

for options, bundle in (
    (os.environ["JAVA_OPTIONS"], os.environ["CA_BUNDLE"]),
    (os.environ["EXTRA_JAVA_OPTIONS"], os.environ["EXTRA_CA_BUNDLE"]),
):
    result = subprocess.run(
        ["java", "-cp", ".", "TestJavaTrustStore"],
        env={**os.environ, "JAVA_TOOL_OPTIONS": options},
        capture_output=True, text=True, check=True,
    )
    actual = set(result.stdout.splitlines())
    assert actual == fingerprints(bundle), "JSSE did not use exactly the shared TLS roots"
    assert expected <= actual
    if bundle == os.environ["EXTRA_CA_BUNDLE"]:
        assert extra <= actual, "Lost the custom CA"

# Empty, malformed, and trusted-only inputs must fail rather than produce a
# silent partial/empty store.
Path("BuildJavaTrustStore.java").write_bytes(Path(os.environ["JAVA_BUILD_SOURCE"]).read_bytes())
subprocess.run(["javac", "BuildJavaTrustStore.java"], check=True)
with tempfile.TemporaryDirectory() as directory:
    source = Path(directory) / "input.pem"
    target = Path(directory) / "store.p12"
    for data in (b"", b"-----BEGIN CERTIFICATE-----\n!\n-----END CERTIFICATE-----\n",
                 Path(os.environ["EXTRA_CA"]).read_bytes().replace(b"CERTIFICATE", b"TRUSTED CERTIFICATE")):
        source.write_bytes(data)
        result = subprocess.run(["java", "-cp", ".", "BuildJavaTrustStore", str(source), str(target)],
                                capture_output=True)
        assert result.returncode != 0 and not target.exists()
print("JSSE roots match the shared bundle; custom CA preserved and invalid inputs rejected")
