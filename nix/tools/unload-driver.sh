set -euo pipefail

usage() {
  echo "Usage: FPGA_BDF=<endpoint> unload-driver" >&2
  echo "Unload the selected endpoint's supported Coyote driver only when it serves no other endpoint." >&2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ $# -gt 0 ]; then usage; exit 1; fi

coyote_unload_preflight
# An unbound endpoint grants no authority to unload any module.
[ -n "$current_module" ] || exit 0

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# Keep the endpoint bound until the kernel accepts module removal. Explicit
# sysfs unbind would bypass module references held by clients with open files.
# Successful module exit unregisters the PCI driver and unbinds the endpoint.
if coyote_driver_loaded "$current_module"; then
  run_as_root rmmod "$current_module"
fi

if coyote_driver_loaded "$current_module" || [ -n "$(coyote_bound_driver "$FPGA_BDF")" ]; then
  echo "ERROR: $current_module remains loaded or endpoint $FPGA_BDF remains bound." >&2
  exit 1
fi
