# Shared CA trust

NixOS, nix-darwin, Home Manager, and the development shell use the policy in
`lib/ca-trust.nix`. The system adapters are `nixos-modules/ca-trust.nix` and
`nix-darwin/modules/ca-trust.nix`; Home Manager uses `home-manager/ca-trust.nix`.

The generated bundles exclude from TLS trust the eMudhra and AAA roots covered
by the pinned NixOS mitigation, including when an older package set is used on
Intel macOS. The blacklist lives in `lib/ca-blacklist.nix`. OpenSSL bundles may
retain a root with explicit rejection flags; certificate presence alone does
not establish TLS trust.
Integrated Home Manager users share the host's generated bundle, including
`security.pki.certificates` and `security.pki.certificateFiles`. Standalone
homes and development shells use a filtered bundle from their own package set.

The environment selects this bundle for OpenSSL/Python, Nix, curl, Git,
Requests, pip, npm, AWS clients, and gRPC clients that honor their standard
CA-file variables. `SSL_CERT_DIR` points to an immutable empty directory to
avoid adding an unrelated OpenSSL fallback store. Node uses
`NODE_OPTIONS=--use-openssl-ca` so Vite+ and downloaded Node runtimes replace
their embedded roots; `NODE_EXTRA_CA_CERTS` alone would only add trust.

For Erlang/Elixir, `ERL_AFLAGS` and `ERL_ZFLAGS` set the `public_key`
application's `cacerts_path` to the same bundle. This changes the default roots
returned by `public_key:cacerts_get/0` on OTP 27.2 and newer. Mix/Hex also receive
`HEX_CACERTS_PATH`. See the [Mix TLS documentation](https://mix.hexdocs.pm/Mix.html#module-ssl-certificates).
Hex must be at least 2.5.2: older releases can still trust their bundled roots
even with this variable set ([upstream advisory](https://github.com/hexpm/hex/security/advisories/GHSA-rw8q-hg7m-cxgr)).
Update existing user archives with `mix local.hex --force` in each relevant
Mix home/runtime. Applications that pass explicit `cacerts`/`cacertfile` TLS
options, use Certifi directly, or replace application configuration can bypass
the BEAM default. In particular, this does not configure Rebar3's separate store.

Java receives `JAVA_TOOL_OPTIONS` selecting a generated PKCS#12 truststore with
`javax.net.ssl.trustStore`, `trustStoreType`, and `trustStorePassword`. This
replaces the default JSSE roots for Java commands and embedded JVMs that inherit
the environment, including separately installed JDKs. The public `changeit`
password protects store integrity; the store contains only public certificates.
`programs.caTrust.javaTrustStore` exposes its immutable path to services that
need explicit configuration. See [Oracle's JAVA_TOOL_OPTIONS documentation](https://docs.oracle.com/en/java/javase/17/troubleshoot/environment-variables-and-system-properties.html).

The Java store includes custom CAs from the shared system bundle. Conversion
imports ordinary `CERTIFICATE` entries only: Nix emits these for server-trusted
CAs, whereas `TRUSTED CERTIFICATE` entries may carry rejection flags. An override
of `programs.caTrust.bundle` must use Nix-generated or compatible PEM with only
server-trusted CAs in its ordinary entries; trusted-only inputs are unsupported.
Applications that explicitly choose another truststore, replace trust managers,
clear `JAVA_TOOL_OPTIONS`, or override its properties need separate settings.
Preserve these three properties when adding other `JAVA_TOOL_OPTIONS` settings.

Managed coding services explicitly inherit `programs.caTrust.environment`.
Linux system and Home Manager user services and Darwin launchd user jobs receive
the CA-file variables, while Node CLI flags are kept in shells and managed coding
services because packaged Electron apps may reject those flags. Applications
with private CA stores or explicit application TLS settings
still need their own updates; this does not rewrite
installed application bundles or macOS Keychains.
An Electron app launched from a shell may need `env -u NODE_OPTIONS`.

Build and activate the host configuration, then start a fresh shell. Existing
applications and services retain their inherited environment until restarted.
The bundle is immutable and rooted by the configuration, so no manual edits to
MacPorts files or Nix store files are needed. Local MacPorts edits made earlier
remain separate and may be overwritten by a MacPorts upgrade.

There is no global `pkgs.cacert` overlay. Only the generated system and client
bundles are filtered, preserving cached package builds and avoiding a large
downstream rebuild. Programs that explicitly select their own bundle and ignore
the configured environment do not inherit this policy.

Validation:

```sh
nix eval --impure --json --file scripts/test-ca-trust-modules.nix
nix build .#checks.x86_64-darwin.ca-trust --no-link
nix build .#checks.x86_64-darwin.java-ca-trust --no-link
nix build .#darwinConfigurations.u3.system --no-link
```

For a checkout with new, untracked module files, use `path:.#...` until those
files are added to Git so the flake includes them.
