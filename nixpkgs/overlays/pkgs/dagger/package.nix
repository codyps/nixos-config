{ lib, stdenv, buildGoModule, fetchFromGitHub, installShellFiles, testers, dagger }:

buildGoModule rec {
  pname = "dagger";
  version = "0.21.12";

  src = fetchFromGitHub {
    owner = "dagger";
    repo = "dagger";
    rev = "v${version}";
    hash = "sha256-b3fUPfys7MoWGUW/6CbWld1Eg64VO20kxhxp70U7AOo=";
  };

  vendorHash = "sha256-p/tyNt19wUwzYA7uzRE8X4E1xWZ1/yiWCxknOlgHX+o=";
  proxyVendor = true;

  subPackages = [
    "cmd/dagger"
  ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/dagger/dagger/engine.Version=v${version}"
    "-X github.com/dagger/dagger/engine.Tag=v${version}"
  ];

  # The CLI tests import engine code that uses Linux-only syscalls.
  doCheck = stdenv.hostPlatform.isLinux;
  # This integration suite connects to a running Dagger engine.
  checkFlags = [ "-skip=^TestDaggerCMD$" ];
  preCheck = ''
    export HOME="$(mktemp -d)"
    export _EXPERIMENTAL_DAGGER_CLI_BIN="$GOPATH/bin/dagger"
  '';

  nativeBuildInputs = [ installShellFiles ];

  postInstall = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
    installShellCompletion --cmd dagger \
      --bash <($out/bin/dagger completion bash) \
      --fish <($out/bin/dagger completion fish) \
      --zsh <($out/bin/dagger completion zsh)
  '';

  passthru.tests.version = testers.testVersion {
    package = dagger;
    command = "dagger version";
    version = "v${version}";
  };

  meta = with lib; {
    description = "A portable devkit for CICD pipelines";
    homepage = "https://dagger.io";
    license = licenses.asl20;
  };
}
