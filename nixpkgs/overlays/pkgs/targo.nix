{
  rustPlatform,
  fetchFromGitHub
}:

rustPlatform.buildRustPackage rec {
  pname = "targo";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "jmesmon";
    repo = "targo";
    rev = "89e3a5e38fa4fe8e0ddfef5e6ec39b4454c71733";
    hash = "";
  };

  cargoHash = "";
}
