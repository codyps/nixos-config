{ pkgs, bundle ? null }:
let
  # Keep older package sets aligned with NixOS's eMudhra mitigation.
  blacklist = import ./ca-blacklist.nix {
    inherit (pkgs) lib;
    inherit (pkgs.cacert) version;
  };
  certificates = pkgs.cacert.override { inherit blacklist; };
  caBundle = if bundle != null then toString bundle else
  "${certificates}/etc/ssl/certs/ca-no-trust-rules-bundle.crt";
  # Prevent OpenSSL clients from falling back to an unrelated CA directory.
  emptyDirectory = pkgs.runCommand "empty-ca-directory" { } ''mkdir -p "$out"'';
  # ERTS parses these as command-line arguments, including the Erlang string term.
  beamFlags = "-public_key cacerts_path ${pkgs.lib.escapeShellArg (builtins.toJSON caBundle)}";
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
    SSL_CERT_FILE = caBundle;
    SSL_CERT_DIR = "${emptyDirectory}";
    NIX_SSL_CERT_FILE = caBundle;
    CURL_CA_BUNDLE = caBundle;
    GIT_SSL_CAINFO = caBundle;
    REQUESTS_CA_BUNDLE = caBundle;
    PIP_CERT = caBundle;
    NPM_CONFIG_CAFILE = caBundle;
    AWS_CA_BUNDLE = caBundle;
    GRPC_DEFAULT_SSL_ROOTS_FILE_PATH = caBundle;
    HEX_CACERTS_PATH = caBundle;
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
