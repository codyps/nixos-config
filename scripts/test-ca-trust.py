#!/usr/bin/env python3
"""Check both compatible PEM bundles and bundles with OpenSSL trust rules."""

import os
from pathlib import Path
import ssl
import subprocess
import tempfile


context = ssl.create_default_context(cafile=os.environ["CA_BUNDLE"])
names = {
    value
    for cert in context.get_ca_certs()
    for rdn in cert["subject"]
    for name, value in rdn
    if name == "commonName"
}
blocked = {
    "AAA Certificate Services",
    "emSign ECC Root CA - G3",
    "emSign Root TLS CA - G3",
    "emSign Root CA - C1",
    "emSign ECC Root CA - C3",
}
assert "ISRG Root X1" in names, "Lost an unrelated public TLS root"
assert len(names) > 80, "The shared TLS trust store is unexpectedly small"
# get_ca_certs also lists explicitly rejected TRUSTED CERTIFICATE entries.
# Verify the actual TLS purpose rather than treating their presence as trust.
checked = set()
with tempfile.TemporaryDirectory() as directory:
    certificate = Path(directory) / "root.pem"
    for der in context.get_ca_certs(binary_form=True):
        subject = subprocess.run(
            ["openssl", "x509", "-inform", "DER", "-noout", "-subject", "-nameopt", "multiline"],
            input=der, capture_output=True, check=True,
        ).stdout.decode()
        common_names = {
            line.split("=", 1)[1].strip()
            for line in subject.splitlines()
            if line.split("=", 1)[0].strip() == "commonName"
        }
        if not common_names & (blocked | {"ISRG Root X1"}):
            continue
        certificate.write_text(ssl.DER_cert_to_PEM_cert(der))
        # Select the TLS server trust policy while allowing CA key usage: these
        # self-signed roots are not server leaf certificates.
        result = subprocess.run(
            ["openssl", "verify", "-CAfile", os.environ["CA_BUNDLE"],
             "-no-CApath", "-no-CAstore", "-verify_name", "ssl_server",
             "-purpose", "any", "-no_check_time",
             str(certificate)],
            capture_output=True, text=True,
        )
        if common_names & blocked:
            assert result.returncode != 0 and "certificate rejected" in result.stderr, (
                f"Affected root was not explicitly rejected: {common_names}: {result.stderr}"
            )
        else:
            assert result.returncode == 0, result.stderr
        checked.update(common_names)
assert "ISRG Root X1" in checked
assert names & blocked <= checked
print(f"Checked {len(names)} CA subjects; affected roots are absent or rejected for TLS")
