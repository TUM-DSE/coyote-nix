set -euo pipefail

module_name="coyote_driver"
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

write_sysfs_line() {
  local value="$1"
  local path="$2"

  if [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' "$value" > "$path"
  else
    printf '%s\n' "$value" | sudo tee "$path" >/dev/null
  fi
}

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

unbind_bdf_from_driver() {
  local bdf="$1"
  local driver="$2"
  local sysfs_path="/sys/bus/pci/drivers/$driver"
  local unbind_path="$sysfs_path/unbind"

  if [ ! -e "$sysfs_path/$bdf" ]; then
    return 0
  fi

  if [ ! -e "$unbind_path" ]; then
    echo "WARN: $driver is present but $unbind_path is missing; probe/remove may be stuck." >&2
    return 1
  fi

  write_sysfs_line "$bdf" "$unbind_path"
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
if [ -n "$requested_bdf" ]; then
  requested_bdf="$(normalize_bdf "$requested_bdf")"
fi

foreign_driver=""
if [ -n "$requested_bdf" ] && [ -e "/sys/bus/pci/devices/$requested_bdf" ]; then
  foreign_driver="$(bound_driver_for_bdf "$requested_bdf" 2>/dev/null || true)"
  if [ -n "$foreign_driver" ] && [ "$foreign_driver" != "$module_name" ]; then
    unbind_bdf_from_driver "$requested_bdf" "$foreign_driver"
    if module_loaded "$foreign_driver"; then
      unload_module "$foreign_driver" || true
    fi
  fi
fi

if module_loaded "$module_name"; then
  if [ -n "$requested_bdf" ] && [ -e "$driver_sysfs/$requested_bdf" ]; then
    unbind_bdf_from_driver "$requested_bdf" "$module_name" || true
  fi

  while IFS= read -r bound_bdf; do
    [ -n "$bound_bdf" ] || continue
    if [ -n "$requested_bdf" ] && [ "$bound_bdf" = "$requested_bdf" ]; then
      continue
    fi
    unbind_bdf_from_driver "$bound_bdf" "$module_name" || true
  done < <(list_bound_bdfs "$driver_sysfs")

  unload_module "$module_name" || true
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
