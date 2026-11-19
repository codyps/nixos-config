{ lib, buildGoModule, fetchFromGitHub }:
buildGoModule rec {
  pname = "redpanda-connect";
  version = "4.117.0";

  src = fetchFromGitHub {
    owner = "redpanda-data";
    repo = "connect";
    rev = "v${version}";
    hash = "sha256-FtKI9Z0JReg0lDKqwkXmya49zIdvxS2h6Enzv4XoNgA=";
  };

  ldflags = [
    "-X main.Version=${version}"
    "-X main.DateBuilt=unknown"
  ];

  subPackages = [
    "cmd/redpanda-connect"
    "cmd/redpanda-connect-community"
  ];

  # otherwise vendorHash changes between macos & linux
  proxyVendor = true;

  vendorHash = "sha256-TMgJdUz3Fkp8ZtsHuznr4tG8dTI33PNNhNBuxB3+ODU=";
}
