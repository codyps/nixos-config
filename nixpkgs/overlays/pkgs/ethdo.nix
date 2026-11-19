{ buildGoModule, fetchFromGitHub, lib }:
buildGoModule rec {
  pname = "ethdo";
  version = "1.39.1";

  src = fetchFromGitHub {
    owner = "wealdtech";
    repo = "ethdo";
    rev = "v${version}";
    hash = "sha256-ByI6MSYExVmTZ/qLaFDGejIJQs7VD/6921QylFxHhCU=";
  };

  vendorHash = "sha256-AK954M3wOiLcNeDAmLjtiTeyyvtE4IUbkSloEbkWRkY=";

  # without this, fails to locate C header used via CGO
  proxyVendor = true;

  meta = with lib; {
    description = "A command-line tool for managing common tasks in Ethereum 2.";
    homepage = "https://github.com/wealdtech/ethdo";
    license = licenses.asl20;
  };
}
