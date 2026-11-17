{ lib, stdenvNoCC, makeWrapper, python3, qemu_kvm, swtpm, OVMFFull, xorriso, _7zz, wimlib }:
stdenvNoCC.mkDerivation {
  pname = "actions-windows-image";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    src = ../scripts/actions-windows-image;
    filter = path: _type: baseNameOf path != "__pycache__";
  };
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/lib/actions-windows-image $out/bin
    cp -r . $out/lib/actions-windows-image/
    makeWrapper ${python3}/bin/python3 $out/bin/actions-windows-image \
      --add-flags "$out/lib/actions-windows-image/image.py" \
      --set ACTIONS_VM_SCALER_GUEST ${../scripts/actions-vm-scaler/guest} \
      --set WINDOWS_OVMF_CODE ${OVMFFull.fd}/FV/OVMF_CODE.ms.fd \
      --set WINDOWS_OVMF_VARS ${OVMFFull.fd}/FV/OVMF_VARS.ms.fd \
      --prefix PATH : ${lib.makeBinPath [ qemu_kvm swtpm xorriso _7zz wimlib ]}
  '';
  meta = {
    description = "Prepare Windows 11 QEMU images for disposable Actions runners";
    mainProgram = "actions-windows-image";
    platforms = [ "x86_64-linux" ];
  };
}
