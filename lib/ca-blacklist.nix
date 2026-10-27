# NSS 3.131.1 removed the three emSign roots. buildcatrust rejects blocklist
# labels absent from its input, so older pins still need the explicit entries.
# https://firefox-source-docs.mozilla.org/security/nss/releases/nss_3_131_1.html
{ lib, version }:
[
  "Comodo AAA Services root"
]
++ lib.optionals (lib.versionOlder version "3.131.1") [
  "emSign ECC Root CA - G3"
  "emSign Root CA - C1"
  "emSign ECC Root CA - C3"
]
