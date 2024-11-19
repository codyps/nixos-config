{ buildGoModule, fetchFromGitHub, lib }:
buildGoModule rec {
  pname = "ethereal";
  version = "2.8.7";

  src = fetchFromGitHub {
    owner = "wealdtech";
    repo = "ethereal";
    rev = "v${version}";
    hash = "sha256-HVqC0w68Cdyh8YBVeQP5xAcrZX3jR010vHjbPF3plRY=";
  };

  vendorHash = "sha256-36r6+1jKqZYkt2aMS20UhjkBx2EJbFVSbm5zb6XPU78=";

  # without this, fails to locate C header used via CGO
  proxyVendor = true;

  # tests require network access, fail when sandboxed
  doCheck = false;

  meta = {
    description = "A command-line tool for managing common tasks in Ethereum";
    homepage = "https://github.com/wealdtech/ethereal";
    license = lib.licenses.apsl20;
  };
}

