{ buildGoModule, fetchFromGitHub, lib }:
buildGoModule rec {
  pname = "ethdo";
  version = "1.36.1";

  src = fetchFromGitHub {
    owner = "wealdtech";
    repo = "ethdo";
    rev = "v${version}";
    hash = "sha256-mv9BlPS5vcpVkMrNZ+E/fOd5xhhk7obDjch3HcyxvI4=";
  };

  vendorHash = "sha256-TIohGH/8t/gW+9TSH6RAkzIr7goiSYABq6JuJZG5UX0=";

  # without this, fails to locate C header used via CGO
  proxyVendor = true;

  meta = with lib; {
    description = "A command-line tool for managing common tasks in Ethereum 2.";
    homepage = "https://github.com/wealdtech/ethdo";
    license = licenses.apsl20;
  };
}
