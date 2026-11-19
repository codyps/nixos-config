{ buildGoModule, fetchFromGitHub, lib }:
buildGoModule rec {
  pname = "ethereal";
  version = "2.12.0";

  src = fetchFromGitHub {
    owner = "wealdtech";
    repo = "ethereal";
    rev = "v${version}";
    hash = "sha256-XPXID0Q0fx/3yJ5LaUBj/xqhMsoOxCNwZOX9vNT7S+k=";
  };

  vendorHash = "sha256-RLcnMVx64Xz+irOo5KPjgjv6XXttVPuzAr+jJkr5ev0=";

  # without this, fails to locate C header used via CGO
  proxyVendor = true;

  # tests require network access, fail when sandboxed
  doCheck = false;

  meta = {
    description = "A command-line tool for managing common tasks in Ethereum";
    homepage = "https://github.com/wealdtech/ethereal";
    license = lib.licenses.asl20;
  };
}

