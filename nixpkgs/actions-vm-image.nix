{ lib, stdenvNoCC, makeWrapper, python3, qemu, git, dmg2img, xorriso, mtools, openssh, tesseract }:
let
  tesseractEnglish = tesseract.override { enableLanguages = [ "eng" ]; };
in
stdenvNoCC.mkDerivation {
  pname = "actions-vm-image";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    src = ../scripts/actions-vm-image;
    filter = path: _type: baseNameOf path != "__pycache__";
  };
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/lib/actions-vm-image $out/bin
    cp -r . $out/lib/actions-vm-image/
    makeWrapper ${python3}/bin/python3 $out/bin/actions-vm-image \
      --add-flags "$out/lib/actions-vm-image/image.py" \
      --set ACTIONS_VM_SCALER_GUEST ${../scripts/actions-vm-scaler/guest} \
      --prefix PATH : ${lib.makeBinPath [ qemu git dmg2img xorriso mtools openssh tesseractEnglish ]}
  '';
  meta = {
    description = "Prepare macOS QEMU images for disposable Actions runners";
    mainProgram = "actions-vm-image";
    platforms = [ "x86_64-linux" ];
  };
}
