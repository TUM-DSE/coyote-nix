#!/usr/bin/env bash
set -euo pipefail

hot_reset=${1:?usage: hot-reset-multifunction.sh HOT_RESET_SCRIPT}
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

pci_root="$workdir/pci"
fake_bin="$workdir/bin"
log="$workdir/tee.log"
mkdir -p "$pci_root/devices" "$fake_bin" \
  "$workdir/topology/0000:c0:01.1/0000:c1:00.0" \
  "$workdir/topology/0000:c0:01.1/0000:c1:00.1"
ln -s "$workdir/topology/0000:c0:01.1" "$pci_root/devices/0000:c0:01.1"
ln -s "$workdir/topology/0000:c0:01.1/0000:c1:00.0" "$pci_root/devices/0000:c1:00.0"
ln -s "$workdir/topology/0000:c0:01.1/0000:c1:00.1" "$pci_root/devices/0000:c1:00.1"
touch "$workdir/topology/0000:c0:01.1/0000:c1:00.0/remove"
touch "$workdir/topology/0000:c0:01.1/0000:c1:00.1/remove"
touch "$pci_root/rescan"

cat > "$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat > "$fake_bin/setpci" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
  BRIDGE_CONTROL) printf '0012\n' ;;
  VENDOR_ID) printf '10ee\n' ;;
  *=*) ;;
  *) exit 1 ;;
esac
EOF
cat > "$fake_bin/tee" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$COYOTE_TEST_TEE_LOG"
exec "$COYOTE_TEST_REAL_TEE" "$@"
EOF
cat > "$fake_bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
bash_path="$(command -v bash)"
for helper in "$fake_bin"/*; do
  sed -i "1s|.*|#!$bash_path|" "$helper"
done
chmod +x "$fake_bin"/*
real_tee="$(command -v tee)"

PATH="$fake_bin:$PATH" \
COYOTE_TEST_TEE_LOG="$log" \
COYOTE_TEST_REAL_TEE="$real_tee" \
COYOTE_NIX_PCI_SYSFS_ROOT="$pci_root" \
COYOTE_NIX_HOT_RESET_SETTLE_S=0 \
COYOTE_NIX_HOT_RESET_RESCAN_SETTLE_S=0 \
COYOTE_NIX_HOT_RESET_READY_POLL_S=0 \
FPGA_BDF=0000:c1:00.0 \
bash "$hot_reset" >/dev/null

mapfile -t writes < "$log"
test "${#writes[@]}" -eq 3
test "${writes[0]}" = "$pci_root/devices/0000:c1:00.1/remove"
test "${writes[1]}" = "$pci_root/devices/0000:c1:00.0/remove"
test "${writes[2]}" = "$pci_root/rescan"
