#!/usr/bin/env bash
# program-cli hands programming to fpga-nix's program-fpga. Check the image,
# port, lock and log settings it passes, using a fake program-fpga.
# Usage: program-cli-delegation.sh <program-cli>
set -euo pipefail

program_cli="${1:?usage: program-cli-delegation.sh PROGRAM_CLI}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/project/images"
# No /usr/bin/env in the Nix sandbox, so use the bash running this test.
{
  echo "#!$(command -v bash)"
  cat <<'EOF'
{
  echo "image=$1"
  echo "port=$FPGA_NIX_HW_SERVER_PORT"
  echo "lock=$FPGA_NIX_PROGRAM_LOCK_DIR"
  echo "build_root=$FPGA_NIX_BUILD_ROOT"
} > "$RECORD"
EOF
} > "$work/bin/program-fpga"
chmod +x "$work/bin/program-fpga"
touch "$work/project/images/top.pdi"

run() {
  (
    cd "$work/project"
    env -u FPGA_NIX_HW_SERVER_PORT -u COYOTE_NIX_HW_SERVER_PORT -u HW_SERVER_PORT \
      -u COYOTE_NIX_PROGRAM_LOCK_DIR -u COYOTE_NIX_BUILD_ROOT -u FPGA_BITSTREAM \
      PATH="$work/bin:$PATH" RECORD="$work/record" COYOTE_NIX_IN_XILINX_DEVSHELL=1 \
      "$@"
  )
}

expect() {
  grep -qxF -- "$1" "$work/record" || {
    echo "FAIL: missing '$1' in:" >&2
    cat "$work/record" >&2
    exit 1
  }
}

# An existing relative image is passed through; V80 defaults to port 3122.
run env FDEV_NAME=v80 bash "$program_cli" images/top.pdi
expect "image=images/top.pdi"
expect "port=3122"
expect "lock=/tmp/coyote-program-cli-v80-3122.lock"
expect "build_root=$work/project/.build"
echo "PASS relative image and V80 defaults"

# Explicit settings win, and FPGA_NIX_HW_SERVER_PORT is preferred.
run env FDEV_NAME=u280 FPGA_NIX_HW_SERVER_PORT=4121 COYOTE_NIX_HW_SERVER_PORT=5121 \
  COYOTE_NIX_PROGRAM_LOCK_DIR="$work/lock" COYOTE_NIX_BUILD_ROOT="$work/build" \
  bash "$program_cli" "$work/project/images/top.pdi"
expect "port=4121"
expect "lock=$work/lock"
expect "build_root=$work/build"
echo "PASS explicit settings"

if run bash "$program_cli" 2>/dev/null; then
  echo "FAIL: program-cli accepted a missing image" >&2
  exit 1
fi
echo "PASS missing image"
