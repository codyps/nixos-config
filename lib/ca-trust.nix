{ pkgs, bundle ? null, runtimeBundle ? null }:
let
  # Keep older package sets aligned with NixOS's eMudhra mitigation.
  blacklist = import ./ca-blacklist.nix {
    inherit (pkgs) lib;
    inherit (pkgs.cacert) version;
  };
  certificates = pkgs.cacert.override { inherit blacklist; };
  caBundle = if bundle != null then toString bundle else
  "${certificates}/etc/ssl/certs/ca-no-trust-rules-bundle.crt";
  clientBundle = if runtimeBundle == null then caBundle else runtimeBundle;
  # Prevent OpenSSL clients from falling back to an unrelated CA directory.
  emptyDirectory = pkgs.runCommand "empty-ca-directory" { } ''mkdir -p "$out"'';
  # Inline `-public_key cacerts_path` needs embedded double quotes, which the
  # nix-darwin, Home Manager, launchd and pam_env writers do not escape. ERTS
  # then logs a syntax error at every start and keeps its default roots. A
  # config file keeps the flag value free of shell and Erlang quoting.
  beamConfig = pkgs.writeText "erlang-ca-trust.config" ''
    [{public_key, [{cacerts_path, ${builtins.toJSON clientBundle}}]}].
  '';
  beamFlags = "-config ${beamConfig}";
  # buildcatrust emits ordinary PEM entries for server-trusted CAs, alongside
  # AUX-bearing TRUSTED entries which must never be blindly imported into Java.
  javaCertificates = pkgs.runCommand "java-ca-truststore"
    { nativeBuildInputs = [ pkgs.jdk ]; } ''
    cp ${../scripts/BuildJavaTrustStore.java} BuildJavaTrustStore.java
    javac BuildJavaTrustStore.java
    mkdir -p "$out"
    java BuildJavaTrustStore ${pkgs.lib.escapeShellArg caBundle} "$out/truststore.p12"
  '';
  javaTrustStore = "${javaCertificates}/truststore.p12";
in
{
  inherit blacklist certificates javaTrustStore;
  bundle = caBundle;
  environment = {
    SSL_CERT_FILE = clientBundle;
    SSL_CERT_DIR = "${emptyDirectory}";
    NIX_SSL_CERT_FILE = clientBundle;
    CURL_CA_BUNDLE = clientBundle;
    GIT_SSL_CAINFO = clientBundle;
    REQUESTS_CA_BUNDLE = clientBundle;
    PIP_CERT = clientBundle;
    NPM_CONFIG_CAFILE = clientBundle;
    # Native Claude uses this explicitly rather than SSL_CERT_FILE.
    # Keep --use-openssl-ca below: extra CAs alone do not replace Node's roots.
    NODE_EXTRA_CA_CERTS = clientBundle;
    AWS_CA_BUNDLE = clientBundle;
    GRPC_DEFAULT_SSL_ROOTS_FILE_PATH = clientBundle;
    HEX_CACERTS_PATH = clientBundle;
    # Replace the default JSSE roots, including for embedded/JNI-launched JVMs.
    # The integrity password is public; this store contains no private keys.
    JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStore=${javaTrustStore} -Djavax.net.ssl.trustStoreType=PKCS12 -Djavax.net.ssl.trustStorePassword=changeit";
    # public_key:cacerts_get/0 honors this on OTP 27.2 and newer.
    ERL_AFLAGS = beamFlags;
    ERL_ZFLAGS = beamFlags;
    # Adding system/extra CAs leaves Node's embedded roots trusted.
    NODE_OPTIONS = "--use-openssl-ca";
  };
}
