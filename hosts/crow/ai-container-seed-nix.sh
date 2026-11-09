# Executed inside a temporary, remapped user namespace with the host store
# read-only and no host Nix socket. Never run this against guest state as host root.
private_nix=$1
closure_paths=$2
mkdir -p "$private_nix/store" "$private_nix/var/nix/profiles"
while IFS= read -r path; do
  case "$path" in
    /nix/store/*) ;;
    *) echo "Invalid bootstrap store path" >&2; exit 1 ;;
  esac
  destination="$private_nix/store/${path##*/}"
  if [ ! -e "$destination" ]; then
    # Reflinks save space without letting guest writes change host store inodes.
    temporary=$(mktemp -d "$private_nix/store/.seed-XXXXXXXX")
    trap 'rm -rf -- "$temporary"' EXIT
    cp -a --reflink=auto --no-preserve=ownership -- "$path" "$temporary/path"
    mv -T -- "$temporary/path" "$destination"
    rmdir "$temporary"
    trap - EXIT
  fi
done < "$closure_paths"
