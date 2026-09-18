# writeShellApplication supplies bash and strict error handling.
if [[ $# -ne 0 ]]; then
  echo 'Usage: sudo warbler-secure-boot-backup' >&2
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo 'Run as root: sudo warbler-secure-boot-backup' >&2
  exit 1
fi
if [[ $(hostname -s) != warbler || ! -d /sys/firmware/efi/efivars ]]; then
  echo 'Run on Warbler booted in UEFI mode.' >&2
  exit 1
fi
if ! mountpoint -q /persist; then
  echo '/persist must be mounted before backing up firmware databases.' >&2
  exit 1
fi

umask 077
backup_root=/persist/secure-boot-backup
mkdir -p "$backup_root"
backup_dir=$(mktemp -d "$backup_root/$(date -u +%Y-%m-%dT%H-%M-%SZ)-XXXXXXXX")
# A failed export leaves evidence, but never a completed-backup marker.
trap 'echo "Backup incomplete: $backup_dir (do not clear firmware keys)." >&2' ERR
printf 'Backup directory: %s\n' "$backup_dir"
sbctl status > "$backup_dir/sbctl-status.txt"
bootctl status > "$backup_dir/bootctl-status.txt"
for variable in PK KEK db dbx; do
  efi-readvar -v "$variable" -o "$backup_dir/$variable.esl" \
    > "$backup_dir/$variable.txt"
  if [[ ! -s "$backup_dir/$variable.esl" ]]; then
    echo "Missing or empty $variable export; backup incomplete: $backup_dir" >&2
    exit 1
  fi
done
cd "$backup_dir"
sha256sum PK.esl KEK.esl db.esl dbx.esl > SHA256SUMS
sha256sum -c SHA256SUMS
touch COMPLETE
printf 'All four databases exported to %s\n' "$backup_dir"
printf 'Copy this directory off-machine and verify SHA256SUMS before changing firmware keys.\n'
