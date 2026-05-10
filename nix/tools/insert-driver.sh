usage() {
  echo "Usage: insert-driver [ko_path] [image_hint]" >&2
  echo "Insert the Coyote kernel driver. If ko_path is omitted, the active dev shell/package defaults are used." >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if [ $# -gt 2 ]; then
  usage
  exit 1
fi

target_platform="$(resolve_target_platform 2>/dev/null || true)"
if [ -z "$target_platform" ]; then
  echo "ERROR: could not determine TARGET_PLATFORM. Set TARGET_PLATFORM explicitly or use a platform devshell." >&2
  exit 1
fi

default_driver_package=""
ko_path=""
if [ $# -ge 1 ]; then
  ko_path="$1"
else
  default_driver_package="$(resolve_driver_package_name "$target_platform" 2>/dev/null || true)"
  if [ -n "$default_driver_package" ]; then
    ko_path="$(resolve_default_driver_ko_from_package "$target_platform" 2>/dev/null || true)"
  fi
fi

image_hint="${2:-${IMAGE_HINT:-}}"
if [ ! -f "$ko_path" ]; then
  echo "ERROR: driver module not found: $ko_path" >&2
  if [ -n "$default_driver_package" ]; then
    echo "Default driver package checked: $default_driver_package" >&2
  fi
  echo "Hint: pass an explicit .ko path, set COYOTE_DRIVER_PACKAGE=<package>, or build the driver package with $(driver_build_hint_for_target_platform "$target_platform")." >&2
  exit 1
fi

module_name="$(basename "$ko_path")"
module_name="${module_name%.ko}"
ready_timeout_s="${COYOTE_NIX_INSERT_DRIVER_READY_TIMEOUT_S:-10}"
ready_poll_s="${COYOTE_NIX_INSERT_DRIVER_READY_POLL_S:-0.2}"

normalize_bdf() {
  local bdf="$1"
  if [ -z "$bdf" ]; then
    return 1
  fi
  if [ -e "/sys/bus/pci/devices/$bdf" ]; then
    echo "$bdf"
    return 0
  fi
  if [ -e "/sys/bus/pci/devices/0000:$bdf" ]; then
    echo "0000:$bdf"
    return 0
  fi
  echo "$bdf"
}

is_driver_bound_to_bdf() {
  local bdf="$1"
  local driver_link="/sys/bus/pci/devices/$bdf/driver"
  [ -L "$driver_link" ] || return 1
  [ "$(basename "$(readlink -f "$driver_link")")" = "$module_name" ]
}

is_driver_ready() {
  local bdf

  if [ -n "${FPGA_BDF:-}" ]; then
    bdf="$(normalize_bdf "$FPGA_BDF")"
    [ -e "/sys/bus/pci/devices/$bdf" ] || return 1
    is_driver_bound_to_bdf "$bdf"
    return $?
  fi

  if compgen -G "/sys/bus/pci/drivers/$module_name/????:??:??.?" >/dev/null; then
    return 0
  fi

  if compgen -G "/dev/coyote_fpga_*_v*" >/dev/null; then
    return 0
  fi

  return 1
}

wait_for_driver_ready() {
  local deadline now
  deadline=$(( $(date +%s) + ready_timeout_s ))

  while :; do
    if is_driver_ready; then
      return 0
    fi

    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      return 1
    fi

    sleep "$ready_poll_s"
  done
}

host="$(hostname)"
mode="host"
if [[ "$image_hint" == *"rdma"* ]] || [[ "$image_hint" == *"tcp"* ]]; then
  mode="network"
fi

driver_args=""
if [ "$mode" = "network" ]; then
  if [[ "$image_hint" == *"tcp"* ]]; then
    echo "TCP bitstream."
    sudo modprobe ice 2>/dev/null || true
    sleep 2
  else
    echo "RDMA bitstream."
  fi

  if [ -n "${COYOTE_DRIVER_ARGS:-}" ]; then
    driver_args="${COYOTE_DRIVER_ARGS}"
  else
    echo "ERROR: network bitstream detected but COYOTE_DRIVER_ARGS is not set for host: $host" >&2
    echo "Set COYOTE_DRIVER_ARGS='ip_addr=... mac_addr=...' and rerun." >&2
    exit 1
  fi
else
  echo "Host bitstream."
fi

set +e
if [ -n "$driver_args" ]; then
  # shellcheck disable=SC2086
  insmod_out="$(sudo insmod "$ko_path" $driver_args 2>&1)"
else
  insmod_out="$(sudo insmod "$ko_path" 2>&1)"
fi
insmod_rc=$?
set -e

if [ "$insmod_rc" -ne 0 ]; then
  if wait_for_driver_ready; then
    echo "Driver $module_name is already loaded and bound."
    exit 0
  fi

  [ -n "$insmod_out" ] && printf '%s\n' "$insmod_out" >&2
  echo "ERROR: failed to insert driver module: $ko_path" >&2
  exit "$insmod_rc"
fi

if ! wait_for_driver_ready; then
  if [ -n "${FPGA_BDF:-}" ]; then
    normalized_bdf="$(normalize_bdf "$FPGA_BDF")"
    bound_driver="none"
    if [ -L "/sys/bus/pci/devices/$normalized_bdf/driver" ]; then
      bound_driver="$(basename "$(readlink -f "/sys/bus/pci/devices/$normalized_bdf/driver")")"
    fi
    echo "ERROR: driver module loaded, but $module_name did not bind to $normalized_bdf (current driver: $bound_driver)." >&2
  else
    echo "ERROR: driver module loaded, but no Coyote device became ready." >&2
  fi
  echo "Hint: inspect sudo dmesg for probe errors such as failed XDMA engine detection." >&2
  exit 1
fi

echo "Driver $module_name loaded and bound."
