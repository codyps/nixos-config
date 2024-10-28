{ buildGoModule
, lib
, fetchFromGitHub
}:

buildGoModule rec {
  pname = "s2";
  version = "1.17.9";

  src = fetchFromGitHub {
    owner = "klauspost";
    repo = "compress";
    rev = "v${version}";
    sha256 = "sha256-bvvOy1LspoBBNwPhv5hW7AyqWvEQ9BMP7B1I51izqkY=";
  };

  vendorHash = null;

  subPackages = [ "s2/cmd/s2c" "s2/cmd/s2d" ];

  ldflags = [ "-s" "-w" ];

  meta = with lib; {
    description = "Go assembler formatter";
    mainProgram = "s2d";
    homepage = "https://github.com/klauspost/compress";
    changelog = "https://github.com/klauspost/compress/releases/tag/${src.rev}";
    license = licenses.mit;
    maintainers = with maintainers; [ kalbasit ];
  };
}
