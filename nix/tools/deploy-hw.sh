program_cmd="program-cli"
image_arg=""
verbosity=0
step_timeout_s=120
program_timeout_s=3600

log_v() {
  if [ "$verbosity" -ge 1 ]; then
    echo "$@"
  fi
  return 0
}

log_vv() {
  if [ "$verbosity" -ge 2 ]; then
    echo "$@"
  fi
  return 0
}

run_with_timeout() {
  local timeout_secs="$1"
  shift

  if [ "$timeout_secs" -gt 0 ]; then
    timeout "${timeout_secs}s" "$@"
  else
    "$@"
  fi
}

run_step() {
  local label="$1"
  local timeout_secs="$2"
  shift 2

  echo "$label"

  if [ "$verbosity" -eq 0 ]; then
    local out rc
    set +e
    out="$(run_with_timeout "$timeout_secs" "$@" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 124 ]; then
        echo "ERROR: step timed out after ${timeout_secs}s: $label" >&2
      else
        echo "ERROR: step failed: $label" >&2
      fi
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      echo "Hint: rerun with -v or -vv for more output." >&2
      exit "$rc"
    fi
    return 0
  fi

  local rc
  if [ "$verbosity" -ge 2 ]; then
    set -x
  fi

  set +e
  run_with_timeout "$timeout_secs" "$@"
  rc=$?
  set -e

  if [ "$verbosity" -ge 2 ]; then
    set +x
  fi

  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then
      echo "ERROR: step timed out after ${timeout_secs}s: $label" >&2
    else
      echo "ERROR: step failed: $label (exit $rc)" >&2
    fi
    exit "$rc"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --program-cmd)
      if [ $# -lt 2 ]; then
        echo "ERROR: --program-cmd requires a value" >&2
        exit 1
      fi
      program_cmd="$2"
      shift 2
      ;;
    -v|--verbose)
      verbosity=1
      shift
      ;;
    -vv|--very-verbose)
      verbosity=2
      shift
      ;;
    --timeout)
      if [ $# -lt 2 ]; then
        echo "ERROR: --timeout requires a value (seconds)" >&2
        exit 1
      fi
      step_timeout_s="$2"
      shift 2
      ;;
    --program-timeout)
      if [ $# -lt 2 ]; then
        echo "ERROR: --program-timeout requires a value (seconds)" >&2
        exit 1
      fi
      program_timeout_s="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: deploy-hw [-v|--verbose] [-vv|--very-verbose] [--timeout <sec>] [--program-timeout <sec>] [--program-cmd '<cmd ...>'] [image.bit|image.pdi]" >&2
      exit 0
      ;;
    --*)
      echo "ERROR: unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [ -n "$image_arg" ]; then
        echo "ERROR: too many positional arguments" >&2
        echo "Usage: deploy-hw [-v|--verbose] [-vv|--very-verbose] [--timeout <sec>] [--program-timeout <sec>] [--program-cmd '<cmd ...>'] [image.bit|image.pdi]" >&2
        exit 1
      fi
      image_arg="$1"
      shift
      ;;
  esac
done

project_root="$(resolve_project_root)"
platform="${FDEV_NAME:-u280}"

default_package=""
default_image=""
if [ -z "$image_arg" ] && [ -z "${FPGA_BITSTREAM:-}" ]; then
  default_package="$(resolve_fpga_package_name "$platform" 2>/dev/null || true)"
  if [ -n "$default_package" ]; then
    default_image="$(resolve_default_fpga_image_from_package "$platform" 2>/dev/null || true)"
  fi
fi

image="${image_arg:-${FPGA_BITSTREAM:-$default_image}}"

if [ -z "${FPGA_BDF:-}" ]; then
  echo "ERROR: FPGA_BDF is required (set it to your device BDF)." >&2
  exit 1
fi

if [ ! -f "$image" ] && [ -f "$project_root/$image" ]; then
  image="$project_root/$image"
fi
if [ ! -f "$image" ]; then
  echo "ERROR: bitstream not found: $image" >&2
  if [ -n "$default_image" ]; then
    echo "Default packaged image checked: $default_image" >&2
  elif [ -n "$default_package" ]; then
    echo "Default package checked: $default_package" >&2
  fi
  echo "Hint: pass an explicit image path, or set FPGA_BITSTREAM=/path/to/image.{bit,pdi}." >&2
  exit 1
fi

case "$step_timeout_s" in
  ''|*[!0-9]*)
    echo "ERROR: --timeout must be a non-negative integer (seconds)." >&2
    exit 1
    ;;
esac

case "$program_timeout_s" in
  ''|*[!0-9]*)
    echo "ERROR: --program-timeout must be a non-negative integer (seconds)." >&2
    exit 1
    ;;
esac

target_platform="$(resolve_target_platform 2>/dev/null || true)"
if [ -z "$target_platform" ]; then
  echo "ERROR: could not determine TARGET_PLATFORM. Set TARGET_PLATFORM explicitly or use a platform devshell." >&2
  exit 1
fi

default_driver_package="$(resolve_driver_package_name "$target_platform" 2>/dev/null || true)"
driver_ko="$(resolve_default_driver_ko_from_package "$target_platform" 2>/dev/null || true)"

if [ ! -f "$driver_ko" ]; then
  echo "ERROR: expected driver module not found: $driver_ko" >&2
  if [ -n "$default_driver_package" ]; then
    echo "Default driver package checked: $default_driver_package" >&2
  fi
  echo "Build it first with: $(driver_build_hint_for_target_platform "$target_platform")" >&2
  exit 1
fi

program_cmd_argv=()
# Split --program-cmd into argv without using a shell wrapper.
# Example: --program-cmd "program-cli --flag value"
read -r -a program_cmd_argv <<< "$program_cmd"
if [ "${#program_cmd_argv[@]}" -eq 0 ] || [ -z "${program_cmd_argv[0]}" ]; then
  echo "ERROR: --program-cmd resolved to an empty command." >&2
  exit 1
fi

log_v "Deploy config: platform=$platform driver platform=$target_platform"
log_v "Image: $image"
log_v "BDF: $FPGA_BDF"
log_v "Driver module: $driver_ko"
log_v "Timeouts: step=${step_timeout_s}s program=${program_timeout_s}s"
log_vv "Program command: ${program_cmd_argv[*]}"

run_step "[1/7] unloading driver" "$step_timeout_s" unload-driver
run_step "[2/7] hot reset (pre-program)" "$step_timeout_s" hot-reset
run_step "[3/7] programming FPGA" "$program_timeout_s" "${program_cmd_argv[@]}" "$image"
run_step "[4/7] hot reset (post-program)" "$step_timeout_s" hot-reset
run_step "[5/7] setting hugepages" "$step_timeout_s" set-hugepages
run_step "[6/7] inserting driver" "$step_timeout_s" insert-driver "$driver_ko" "$image"
echo "[7/7] complete."
