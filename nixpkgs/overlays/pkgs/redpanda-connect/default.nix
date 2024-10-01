{ lib, buildGoModule, fetchFromGitHub }:
buildGoModule rec {
  pname = "redpanda-connect";
  version = "4.37.0";

  src = fetchFromGitHub {
    owner = "redpanda-data";
    repo = "connect";
    rev = "v${version}";
    hash = "sha256-N5v4ww7crEXAFqp0UgAXldDIONLTNmAqZsEF/aqz8xo=";
  };

  ldflags = [
    "-X main.Version=${version}"
    "-X main.DateBuilt=unknown"
  ];

  subPackages = [
    "cmd/redpanda-connect"
    "cmd/redpanda-connect-community"
  ];

  vendorHash = "sha256-Ic72mcklq+MOIK48TsaAh98Twy7YcuxkqZS16SQx2Yk=";
}
