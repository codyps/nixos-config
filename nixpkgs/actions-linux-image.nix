{ runCommand, qemu_kvm, OVMF, guest }:
runCommand "actions-linux-image"
{
  nativeBuildInputs = [ qemu_kvm ];
}
''
  mkdir -p "$out"
  qemu-img convert -f raw -O qcow2 -c \
    "${guest.system.build.image}/${guest.image.filePath}" "$out/base.qcow2"
  cat > "$out/vm.json" <<EOF
  {
    "guest_os": "linux",
    "base_disk": "$out/base.qcow2",
    "firmware_code": "${OVMF.fd}/FV/OVMF_CODE.fd",
    "firmware_vars": "${OVMF.fd}/FV/OVMF_VARS.fd",
    "hardware_args": ["-machine", "q35", "-cpu", "host"]
  }
  EOF
''
