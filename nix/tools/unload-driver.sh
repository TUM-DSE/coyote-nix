set -euo pipefail

usage() {
  echo "Usage: FPGA_BDF=<endpoint> unload-driver" >&2
  echo "Unload coyote_driver only when it serves no other endpoint." >&2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ $# -gt 0 ]; then usage; exit 1; fi

coyote_unload_preflight

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if [ -n "$(coyote_bound_driver "$FPGA_BDF")" ]; then
  unbind_path=/sys/bus/pci/drivers/coyote_driver/unbind
  if [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' "$FPGA_BDF" > "$unbind_path"
  else
    printf '%s\n' "$FPGA_BDF" | sudo tee "$unbind_path" >/dev/null
  fi
fi

if coyote_driver_loaded; then
  run_as_root rmmod coyote_driver
fi

if coyote_driver_loaded || [ -n "$(coyote_bound_driver "$FPGA_BDF")" ]; then
  echo "ERROR: coyote_driver remains loaded or endpoint $FPGA_BDF remains bound." >&2
  exit 1
fi
