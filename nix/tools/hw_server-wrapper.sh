set -euo pipefail

# shellcheck source=/dev/null
source "@XILINX_WRAPPER_LIB@"

case "${1:-}" in
  -h|--help)
    set -- -help "${@:2}"
    ;;
esac

coyote_nix_hw_server_port_for_wrapper() {
  if [ -n "${COYOTE_NIX_HW_SERVER_PORT:-}" ]; then
    printf '%s\n' "$COYOTE_NIX_HW_SERVER_PORT"
    return 0
  fi
  if [ -n "${HW_SERVER_PORT:-}" ]; then
    printf '%s\n' "$HW_SERVER_PORT"
    return 0
  fi

  case "${FDEV_NAME:-${COYOTE_NIX_PLATFORM:-}}" in
    v80|*v80*|versal|*versal*) printf '%s\n' 3122 ;;
    *) printf '%s\n' 3121 ;;
  esac
}

coyote_nix_prepare_hw_server_log_for_wrapper() {
  local log_path="$1"
  local fallback_path="${2:-}"

  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
  if : >>"$log_path" 2>/dev/null; then
    chmod a+rw "$log_path" 2>/dev/null || true
    printf '%s\n' "$log_path"
    return 0
  fi

  if [ -n "$fallback_path" ] && [ "$fallback_path" != "$log_path" ]; then
    mkdir -p "$(dirname "$fallback_path")"
    : >>"$fallback_path"
    chmod a+rw "$fallback_path" 2>/dev/null || true
    echo "hw_server: log $log_path is not writable; using $fallback_path" >&2
    printf '%s\n' "$fallback_path"
    return 0
  fi

  echo "ERROR: hw_server log is not writable: $log_path" >&2
  return 1
}

version="$(coyote_nix_pick_xilinx_version_for coyote_nix_find_vivado_bin 2>/dev/null || true)"
if [ -z "$version" ]; then
  echo "hw_server not found under $(coyote_nix_xilinx_share_root)" >&2
  exit 1
fi

vivado_bin="$(coyote_nix_find_vivado_bin "$version" 2>/dev/null || true)"
if [ -z "$vivado_bin" ]; then
  echo "Vivado $version not found under $(coyote_nix_xilinx_share_root)" >&2
  exit 1
fi

vivado_root="$(dirname "$(dirname "$vivado_bin")")"
hw_server_bin="$vivado_root/bin/hw_server"
if [ ! -x "$hw_server_bin" ]; then
  echo "hw_server not found for Vivado $version under $(coyote_nix_xilinx_share_root)" >&2
  exit 1
fi

umask 000

has_log_file=0
has_server_url=0
extra_args=()
user_args=()
hw_server_port="$(coyote_nix_hw_server_port_for_wrapper)"
fallback_hw_server_log="${TMPDIR:-/tmp}/hw_server-$(id -u)-$hw_server_port.log"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -L)
      has_log_file=1
      user_args+=("$1")
      shift
      if [ "$#" -eq 0 ]; then
        echo "ERROR: -L requires a log path" >&2
        exit 1
      fi
      if [ "$1" = "-" ]; then
        user_args+=("$1")
      else
        hw_server_log="$(coyote_nix_prepare_hw_server_log_for_wrapper "$1" "$fallback_hw_server_log")"
        user_args+=("$hw_server_log")
      fi
      ;;
    -L*)
      has_log_file=1
      hw_server_log="${1#-L}"
      if [ "$hw_server_log" = "-" ]; then
        user_args+=("$1")
      else
        hw_server_log="$(coyote_nix_prepare_hw_server_log_for_wrapper "$hw_server_log" "$fallback_hw_server_log")"
        user_args+=("-L$hw_server_log")
      fi
      ;;
    -s)
      has_server_url=1
      user_args+=("$1")
      shift
      if [ "$#" -eq 0 ]; then
        echo "ERROR: -s requires a server URL" >&2
        exit 1
      fi
      user_args+=("$1")
      ;;
    -s*)
      has_server_url=1
      user_args+=("$1")
      ;;
    *)
      user_args+=("$1")
      ;;
  esac
  shift
done

if [ "$has_log_file" -eq 0 ]; then
  if [ -n "${HW_SERVER_LOG:-}" ]; then
    hw_server_log="$HW_SERVER_LOG"
  elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; then
    hw_server_log="$XDG_RUNTIME_DIR/hw_server-$hw_server_port.log"
  else
    hw_server_log="$fallback_hw_server_log"
  fi

  hw_server_log="$(coyote_nix_prepare_hw_server_log_for_wrapper "$hw_server_log" "$fallback_hw_server_log")"
  extra_args+=("-L$hw_server_log")
fi

if [ "$has_server_url" -eq 0 ]; then
  extra_args+=("-s" "tcp::$hw_server_port")
fi

coyote_nix_exec_xilinx_tool "$version" "$hw_server_bin" "${extra_args[@]}" "${user_args[@]}"
