{ lib, stdenv, buildGoModule, fetchFromGitHub, installShellFiles, testers, dagger }:

buildGoModule rec {
  pname = "dagger";
  version = "0.12.5";

  src = fetchFromGitHub {
    owner = "dagger";
    repo = "dagger";
    rev = "v${version}";
    hash = "sha256-vYFDpmQgGPcK48ikxxoSs2b0kSBH86CMD7KhTbWk94M=";
  };

  vendorHash = "sha256-Lms/0Lz3IVkBbo2gWvU2AZpOr3ZapOrx0HrZA21oFVo=";
  proxyVendor = true;

  subPackages = [
    "cmd/dagger"
  ];

  ldflags = [ "-s" "-w" "-X github.com/dagger/dagger/engine.Version=${version}" ];

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
