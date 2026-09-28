{ lib, stdenvNoCC, fetchurl }:
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
  garm = release {
    name = "garm";
    version = "0.2.1";
    repo = "garm";
    hash = "sha256-ERdqy4pyX5FLm5R4kbSDfTdPthYZVWLMCtRae+i2x0Y=";
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
