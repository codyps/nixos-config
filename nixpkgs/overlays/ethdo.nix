self: super: {
  ethdo = super.buildGoModule rec {
    pname = "ethdo";
    version = "1.30.0";

    src = super.fetchFromGitHub {
      owner = "wealdtech";
      repo = "ethdo";
      rev = "v${version}";
      hash = "sha256-prV1sfvjUe1VPqh/M8C9d1flfTYU1nYTw6GIdJe4src=";
    };

    vendorHash = "sha256-iA1CEZOKwQq8khsIcQVJaJKhiIsQ5YPPQ+RInfQLP6c=";

    # without this, fails to locate C header used via CGO
    proxyVendor = true;

    meta = with super.lib; {
      description = "A command-line tool for managing common tasks in Ethereum 2.";
      homepage = "https://github.com/wealdtech/ethdo";
      license = licenses.apsl20;
    };
  };

  ethereal = super.buildGoModule rec {
    pname = "ethereal";
    version = "2.8.7";

    src = super.fetchFromGitHub {
      owner = "wealdtech";
      repo = "ethereal";
      rev = "v${version}";
      hash = "sha256-HVqC0w68Cdyh8YBVeQP5xAcrZX3jR010vHjbPF3plRY=";
    };

    vendorHash = "sha256-zm1rrkET8MdHIPSMZZfx6iwXrBCNaE4ZfrylDuDdwJM=";

    # without this, fails to locate C header used via CGO
    proxyVendor = true;

    # tests require network access, fail when sandboxed
    doCheck = false;

    meta = with super.lib; {
      description = "A command-line tool for managing common tasks in Ethereum";
      homepage = "https://github.com/wealdtech/ethereal";
      license = licenses.apsl20;
    };
  };

  ethereum-staking-deposit-cli = super.python3Packages.buildPythonApplication rec {
    pname = "ethereum-staking-deposit-cli";
    version = "2.5.0";

    src = super.fetchFromGitHub {
      owner = "ethereum";
      repo = "staking-deposit-cli";
      rev = "v${version}";
      hash = "";
    };

    #nativeBuildInputs = [ super.python3Packages.setuptools ];

    meta = with super.lib; {
      description = "Secure key generation for deposits";
      homepage = "https://github.com/ethereum/staking-deposit-cli";
      license = licenses.cc0;
    };
  };
}
