{ lib, stdenvNoCC, fetchurl, buildGoModule, fetchFromGitHub }:
let
  # Upstream publishes static binaries, including the embedded web UI.
  release = { name, version, repo, hash }: stdenvNoCC.mkDerivation {
    pname = name;
    inherit version;
    src = fetchurl {
      url = "https://github.com/cloudbase/${repo}/releases/download/v${version}/${name}-linux-amd64.tgz";
      inherit hash;
    };
    sourceRoot = ".";
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      install -Dm755 ${name} $out/bin/${name}
      runHook postInstall
    '';
    meta = {
      license = lib.licenses.asl20;
      platforms = [ "x86_64-linux" ];
      mainProgram = name;
    };
  };
in
{
  garm = buildGoModule {
    pname = "garm";
    version = "0.2.1";
    src = fetchFromGitHub {
      owner = "cloudbase";
      repo = "garm";
      rev = "154638445c3949c1958b01812f69d9a1e4d82684";
      hash = "sha256-Eqa0gnPm/puaxVqODJ+nwphYgt0crN6D/OmRijzmZ/M=";
    };
    vendorHash = null;
    patches = [ ./garm-auth.patch ];
    subPackages = [ "cmd/garm" ];
    tags = [ "osusergo" "netgo" "sqlite_omit_load_extension" ];
    ldflags = [ "-s" "-w" "-X github.com/cloudbase/garm/util/appdefaults.Version=0.2.1" ];
    checkPhase = ''
      runHook preCheck
      go test ./params ./util/github/scalesets
      go test ./workers/entity ./workers/scaleset -run TestWorkerReusesActionsClientAndUpdatesCredentials
      runHook postCheck
    '';
    meta = {
      license = lib.licenses.asl20;
      platforms = [ "x86_64-linux" ];
      mainProgram = "garm";
    };
  };
  cli = release {
    name = "garm-cli";
    version = "0.2.1";
    repo = "garm";
    hash = "sha256-mD+lRVfz9c46oe6yOHSZ9fgj0UUSoFWbqIhme8Oz6I4=";
  };
  provider = release {
    name = "garm-provider-incus";
    version = "0.1.5";
    repo = "garm-provider-incus";
    hash = "sha256-FIm1+bPwFSjjOMYEwT2r6DIe1vG8bed8c0QRnXcxxD8=";
  };
}
