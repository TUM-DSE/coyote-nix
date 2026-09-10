#!/usr/bin/env bash
set -euo pipefail
hot_reset=${1:?usage: hot-reset-multifunction.sh HOT_RESET_SCRIPT}
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
export COYOTE_TEST_ROOT="$workdir"
fake_bin="$workdir/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat > "$fake_bin/setpci" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${*: -1}" in
  PRIMARY_BUS) echo c0 ;;
  SECONDARY_BUS) cat "$COYOTE_TEST_ROOT/secondary" ;;
  SUBORDINATE_BUS) echo c2 ;;
  BRIDGE_CONTROL) cat "$COYOTE_TEST_ROOT/control" ;;
  BRIDGE_CONTROL=*)
    echo "${*: -1}" >> "$COYOTE_TEST_ROOT/mutations"
    echo "${*: -1}" | cut -d= -f2 > "$COYOTE_TEST_ROOT/control"
    if [[ "$COYOTE_TEST_MODE" == assertion-failure && "${*: -1}" == BRIDGE_CONTROL=0052 ]]; then exit 1; fi
    if [[ "$COYOTE_TEST_MODE" == restore-readback && "${*: -1}" == BRIDGE_CONTROL=0012 ]]; then echo ffff > "$COYOTE_TEST_ROOT/control"; fi
    ;;
  VENDOR_ID)
    echo ready >> "$COYOTE_TEST_ROOT/reads"
    if [[ "$COYOTE_TEST_MODE" == readiness-failure ]]; then echo ffff; else echo 10ee; fi ;;
  *) exit 1 ;;
esac
EOF
cat > "$fake_bin/tee" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "$COYOTE_TEST_ROOT/mutations"
value=$(cat)
printf '%s\n' "$value" | "$COYOTE_TEST_REAL_TEE" "$@"
case "$1" in
  */remove)
    name=$(basename "$(dirname "$1")")
    printf '%s\n' "$name" >> "$COYOTE_TEST_ROOT/removed"
    rm "$COYOTE_NIX_PCI_SYSFS_ROOT/devices/$name"
    ;;
  */pci_bus/0000:c1/rescan)
    count=$(( $(cat "$COYOTE_TEST_ROOT/scans") + 1 ))
    printf '%s\n' "$count" > "$COYOTE_TEST_ROOT/scans"
    if [[ "$COYOTE_TEST_MODE" == never-discovered ]]; then exit 0; fi
    if [[ "$COYOTE_TEST_MODE" == missed-first-scan && "$count" == 1 ]]; then exit 0; fi
    if [[ "$COYOTE_TEST_MODE" == retry-range ]]; then
      echo c2 > "$COYOTE_TEST_ROOT/secondary"
      exit 0
    fi
    if [[ "$COYOTE_TEST_MODE" == retry-foreign || "$COYOTE_TEST_MODE" == rediscovery-foreign ]]; then
      parent="$COYOTE_TEST_ROOT/topology/0000:c0:01.1"
      mkdir -p "$parent/0000:c1:01.0"
      ln -s "$parent/0000:c1:01.0" "$COYOTE_NIX_PCI_SYSFS_ROOT/devices/0000:c1:01.0"
      if [[ "$COYOTE_TEST_MODE" == retry-foreign ]]; then exit 0; fi
    fi
    while read -r name; do
      ln -s "$COYOTE_TEST_ROOT/topology/0000:c0:01.1/$name" "$COYOTE_NIX_PCI_SYSFS_ROOT/devices/$name"
    done < "$COYOTE_TEST_ROOT/removed"
    ;;
esac
EOF
cat > "$fake_bin/sleep" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == 0.125 ]]; then
  case "$COYOTE_TEST_MODE" in
    hold-failure) exit 1 ;;
    term) kill -TERM "$PPID" ;;
    concurrent) echo 0053 > "$COYOTE_TEST_ROOT/control" ;;
  esac
fi
EOF
bash_path="$(command -v bash)"
for helper in "$fake_bin"/*; do
  sed -i "1s|.*|#!$bash_path|" "$helper"
done
chmod +x "$fake_bin"/*
COYOTE_TEST_REAL_TEE="$(command -v tee)"
export COYOTE_TEST_REAL_TEE
export PATH="$fake_bin:$PATH"
export COYOTE_NIX_PCI_SYSFS_ROOT="$workdir/pci"
export COYOTE_NIX_HOT_RESET_HOLD_S=0.125
export COYOTE_NIX_HOT_RESET_SETTLE_S=0
export COYOTE_NIX_HOT_RESET_RESCAN_SETTLE_S=0
export COYOTE_NIX_HOT_RESET_READY_POLL_S=0
export COYOTE_NIX_HOT_RESET_READY_TIMEOUT_S=1
export FPGA_BDF=0000:c1:00.0
pci_root="$COYOTE_NIX_PCI_SYSFS_ROOT"
bridge="$workdir/topology/0000:c0:01.1"
add_function() {
  local name="$1" parent="${2:-$bridge}"
  mkdir -p "$parent/$name"
  ln -s "$parent/$name" "$pci_root/devices/$name"
  echo 0x10ee > "$parent/$name/vendor"
  echo 0x120000 > "$parent/$name/class"
  touch "$parent/$name/remove"
}
setup() {
  rm -rf "$pci_root" "$workdir/topology"
  mkdir -p "$pci_root/devices" "$bridge/pci_bus/0000:c1"
  ln -s "$bridge" "$pci_root/devices/0000:c0:01.1"
  echo 0x060400 > "$bridge/class"
  touch "$bridge/pci_bus/0000:c1/rescan" "$pci_root/rescan"
  add_function 0000:c1:00.0
  add_function 0000:c1:00.1
  echo 0012 > "$workdir/control"
  echo c1 > "$workdir/secondary"
  : > "$workdir/mutations"
  : > "$workdir/reads"
  : > "$workdir/removed"
  echo 0 > "$workdir/scans"
  export COYOTE_TEST_MODE=normal
}
run() { timeout 8 bash "$hot_reset" > "$workdir/output" 2>&1; }
reject() {
  if run; then echo "unexpected success: $case_name"; exit 1; fi
  test ! -s "$workdir/mutations"
  echo "PASS zero mutation: $case_name"
}
for case_name in foreign nested bound-selected bound-sibling foreign-vendor ffff asserted invalid missing-scan range-outsider; do
  setup
  case "$case_name" in
    foreign) add_function 0000:c1:01.0 ;;
    nested) add_function 0000:c2:00.0 "$bridge/0000:c1:00.1" ;;
    bound-selected) ln -s "$workdir/driver" "$bridge/0000:c1:00.0/driver" ;;
    bound-sibling) ln -s "$workdir/driver" "$bridge/0000:c1:00.1/driver" ;;
    foreign-vendor) echo 0x1234 > "$bridge/0000:c1:00.1/vendor" ;;
    ffff) echo ffff > "$workdir/control" ;;
    asserted) echo 0052 > "$workdir/control" ;;
    invalid) echo nope > "$workdir/control" ;;
    missing-scan) rm "$bridge/pci_bus/0000:c1/rescan" ;;
    range-outsider) add_function 0000:c2:00.0 "$workdir/topology" ;;
  esac
  reject
done
for case_name in assertion-failure hold-failure term concurrent restore-readback readiness-failure; do
  setup
  export COYOTE_TEST_MODE="$case_name"
  if run; then echo "unexpected success: $case_name"; exit 1; fi
  mapfile -t writes < "$workdir/mutations"
  test "${writes[0]}" = BRIDGE_CONTROL=0052
  if [[ "$case_name" == concurrent ]]; then
    test "${#writes[@]}" -eq 1
    test "$(< "$workdir/control")" = 0053
  else
    test "${#writes[@]}" -eq 2
    test "${writes[1]}" = BRIDGE_CONTROL=0012
    if [[ "$case_name" == restore-readback ]]; then
      test "$(< "$workdir/control")" = ffff
    else
      test "$(< "$workdir/control")" = 0012
    fi
  fi
  echo "PASS failure/restore: $case_name"
done
for case_name in single multifunction no-rescan; do
  setup
  if [[ "$case_name" == single ]]; then
    rm "$pci_root/devices/0000:c1:00.1"
    rm -rf "$bridge/0000:c1:00.1"
  fi
  if [[ "$case_name" == no-rescan ]]; then
    export COYOTE_NIX_HOT_RESET_PCI_RESCAN=0
    rm "$bridge/pci_bus/0000:c1/rescan" "$bridge"/0000:c1:00.*/remove
  fi
  run || { cat "$workdir/output"; exit 1; }
  unset COYOTE_NIX_HOT_RESET_PCI_RESCAN
  mapfile -t writes < "$workdir/mutations"
  test "${writes[0]}" = BRIDGE_CONTROL=0052
  test "${writes[1]}" = BRIDGE_CONTROL=0012
  case "$case_name" in
    single) test "${#writes[@]}" -eq 4 ;;
    multifunction)
      test "${#writes[@]}" -eq 5
      test "${writes[2]}" = "$pci_root/devices/0000:c1:00.1/remove" ;;
    no-rescan) test "${#writes[@]}" -eq 2 ;;
  esac
  if [[ "$case_name" != no-rescan ]]; then
    test "${writes[-2]}" = "$pci_root/devices/0000:c1:00.0/remove"
    test "${writes[-1]}" = "$bridge/pci_bus/0000:c1/rescan"
  fi
  test ! -s "$pci_root/rescan"
  test -s "$workdir/reads"
  echo "PASS readiness and scoped rescan: $case_name"
done

export COYOTE_NIX_HOT_RESET_READY_TIMEOUT_S=3
for case_name in missed-first-scan never-discovered retry-foreign rediscovery-foreign retry-range; do
  setup
  export COYOTE_TEST_MODE="$case_name"
  if [[ "$case_name" == missed-first-scan ]]; then
    run || { cat "$workdir/output"; exit 1; }
    test "$(< "$workdir/scans")" -eq 2
    test -e "$pci_root/devices/$FPGA_BDF"
  else
    if run; then echo "unexpected success: $case_name"; exit 1; fi
    if [[ "$case_name" == rediscovery-foreign ]]; then
      test -e "$pci_root/devices/$FPGA_BDF"
    else
      test ! -e "$pci_root/devices/$FPGA_BDF"
    fi
    if [[ "$case_name" == retry-foreign || "$case_name" == rediscovery-foreign ]]; then
      test "$(< "$workdir/scans")" -eq 1
      grep -F 'foreign descendant' "$workdir/output" >/dev/null
    elif [[ "$case_name" == retry-range ]]; then
      test "$(< "$workdir/scans")" -eq 1
      grep -F 'bus range changed' "$workdir/output" >/dev/null
    else
      grep -F 'did not reappear within' "$workdir/output" >/dev/null
      test "$(< "$workdir/scans")" -ge 1
    fi
  fi
  test "$(grep -c '^BRIDGE_CONTROL=' "$workdir/mutations")" -eq 2
  test "$(< "$workdir/control")" = 0012
  test ! -s "$pci_root/rescan"
  echo "PASS bounded rediscovery: $case_name"
done
