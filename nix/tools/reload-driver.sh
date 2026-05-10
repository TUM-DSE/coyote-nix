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

if [ ! -f "$ko_path" ]; then
  echo "ERROR: driver module not found: $ko_path" >&2
  if [ -n "$default_driver_package" ]; then
    echo "Default driver package checked: $default_driver_package" >&2
  fi
  echo "Hint: pass an explicit .ko path, set COYOTE_DRIVER_PACKAGE=<package>, or build the driver package with $(driver_build_hint_for_target_platform "$target_platform")." >&2
  exit 1
fi

unload-driver
sudo insmod "$ko_path"
