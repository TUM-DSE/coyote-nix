set -euo pipefail

usage() {
  echo "Usage: unload-driver" >&2
  echo "Remove COYOTE_MODULE_NAME (default coyote_driver). FPGA_BDF restricts removal to a module owning no other endpoint; foreign drivers are never changed." >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if [ $# -gt 0 ]; then
  usage
  exit 1
fi

module_name="${COYOTE_MODULE_NAME:-coyote_driver}"
case "$module_name" in
  coyote_driver|coyote_driver_ultrascale_plus|coyote_driver_versal) ;;
  *) echo "ERROR: unsupported COYOTE_MODULE_NAME: $module_name" >&2; exit 1 ;;
esac
driver_sysfs="/sys/bus/pci/drivers/$module_name"

module_loaded() {
  local name="$1"
  grep -q "^${name} " /proc/modules
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

normalize_bdf() {
  local bdf="$1"

  if [[ ! "$bdf" =~ ^([[:xdigit:]]{4}:)?[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]]; then
    echo "ERROR: invalid PCI endpoint BDF: $bdf" >&2
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

bound_driver_for_bdf() {
  local bdf="$1"
  local driver_link="/sys/bus/pci/devices/$bdf/driver"

  if [ ! -L "$driver_link" ]; then
    return 1
  fi

  basename "$(readlink -f "$driver_link")"
}

list_bound_bdfs() {
  local sysfs_path="$1"
  local path

  if [ ! -d "$sysfs_path" ]; then
    return 0
  fi

  shopt -s nullglob
  for path in "$sysfs_path"/????:??:??.?; do
    basename "$path"
  done
  shopt -u nullglob
}

unload_module() {
  local name="$1"
  local rc

  if ! module_loaded "$name"; then
    return 0
  fi

  set +e
  run_as_root rmmod "$name"
  rc=$?
  set -e
  return "$rc"
}

requested_bdf="${FPGA_BDF:-}"
if [ -z "$requested_bdf" ]; then
  echo "ERROR: FPGA_BDF is required; refusing ambiguous module-wide removal." >&2
  exit 1
fi
requested_bdf="$(normalize_bdf "$requested_bdf")"

foreign_driver=""
if [ -n "$requested_bdf" ] && [ -e "/sys/bus/pci/devices/$requested_bdf" ]; then
  foreign_driver="$(bound_driver_for_bdf "$requested_bdf" 2>/dev/null || true)"
  if [ -n "$foreign_driver" ] && [ "$foreign_driver" != "$module_name" ]; then
    echo "ERROR: $requested_bdf belongs to $foreign_driver, not $module_name; refusing to change either driver." >&2
    exit 1
  fi
fi

if module_loaded "$module_name"; then
  # Module removal affects every bound endpoint; validate scope before mutation.
  while IFS= read -r bound_bdf; do
    [ -n "$bound_bdf" ] || continue
    if [ -n "$requested_bdf" ] && [ "$bound_bdf" != "$requested_bdf" ]; then
      echo "ERROR: $module_name also owns $bound_bdf; refusing module-wide removal for $requested_bdf." >&2
      exit 1
    fi
  done < <(list_bound_bdfs "$driver_sysfs")

  # Let normal module teardown perform unbinding. Never force or mask failure.
  unload_module "$module_name"
fi

if module_loaded "$module_name"; then
  echo "ERROR: failed to unload $module_name" >&2
  if [ -r "/sys/module/$module_name/initstate" ]; then
    echo "initstate: $(cat "/sys/module/$module_name/initstate")" >&2
  fi
  if [ -r "/sys/module/$module_name/refcnt" ]; then
    echo "refcnt: $(cat "/sys/module/$module_name/refcnt")" >&2
  fi
  if [ -d "$driver_sysfs" ]; then
    bound_now="$(list_bound_bdfs "$driver_sysfs" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"
    if [ -n "$bound_now" ]; then
      echo "still bound to: $bound_now" >&2
    fi
  fi
  echo "Hint: inspect sudo dmesg for stuck probe/remove paths." >&2
  exit 1
fi

if [ -n "$requested_bdf" ] && [ -e "/sys/bus/pci/devices/$requested_bdf" ]; then
  remaining_driver="$(bound_driver_for_bdf "$requested_bdf" 2>/dev/null || true)"
  if [ -n "$remaining_driver" ]; then
    echo "ERROR: device $requested_bdf is still bound to driver $remaining_driver" >&2
    echo "Hint: unload or unbind that driver before programming." >&2
    exit 1
  fi
fi
