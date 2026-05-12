set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    exit 1
  fi
}

coyote_nix_hw_server_port() {
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

coyote_nix_prepare_hw_server_log() {
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

resolve_project_root() {
  if git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "$git_root"
    return 0
  fi
  echo "$PWD"
}

resolve_flake_ref() {
  local project_root

  project_root="$(resolve_project_root)"
  if [ -f "$project_root/flake.nix" ]; then
    echo "$project_root"
  else
    echo "."
  fi
}

coyote_nix_platform_family() {
  case "$1" in
    v80|*v80*|versal|*versal*) echo "versal" ;;
    u280|*u280*|ultrascale|*ultrascale*) echo "ultrascale" ;;
    *) return 1 ;;
  esac
}

default_fpga_package_for_platform() {
  local family
  family="$(coyote_nix_platform_family "$1")" || return 1

  case "$family" in
    versal)
      [ -n "${COYOTE_NIX_VERSAL_FPGA_PACKAGE:-}" ] || return 1
      echo "$COYOTE_NIX_VERSAL_FPGA_PACKAGE"
      ;;
    ultrascale)
      [ -n "${COYOTE_NIX_ULTRASCALE_FPGA_PACKAGE:-}" ] || return 1
      echo "$COYOTE_NIX_ULTRASCALE_FPGA_PACKAGE"
      ;;
    *) return 1 ;;
  esac
}

default_fpga_artifact_for_platform() {
  local family
  family="$(coyote_nix_platform_family "$1")" || family="ultrascale"

  case "$family" in
    versal)
      echo "${COYOTE_NIX_VERSAL_FPGA_ARTIFACT:-cyt_top.pdi}"
      ;;
    *)
      echo "${COYOTE_NIX_ULTRASCALE_FPGA_ARTIFACT:-cyt_top.bit}"
      ;;
  esac
}

default_target_platform_for_platform() {
  case "$1" in
    v80|*v80*|versal|*versal*)
      echo "versal"
      ;;
    u280|*u280*|ultrascale|*ultrascale*)
      echo "ultrascale_plus"
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_target_platform() {
  if [ -n "${TARGET_PLATFORM:-}" ]; then
    echo "$TARGET_PLATFORM"
    return 0
  fi

  if [ -n "${COYOTE_NIX_TARGET_PLATFORM:-}" ]; then
    echo "$COYOTE_NIX_TARGET_PLATFORM"
    return 0
  fi

  default_target_platform_for_platform "${COYOTE_NIX_PLATFORM:-${FDEV_NAME:-}}"
}

resolve_fpga_package_name() {
  local platform="$1"

  if [ -n "${FPGA_PACKAGE:-}" ]; then
    echo "$FPGA_PACKAGE"
    return 0
  fi

  if [ -n "${COYOTE_NIX_FPGA_PACKAGE:-}" ]; then
    echo "$COYOTE_NIX_FPGA_PACKAGE"
    return 0
  fi

  default_fpga_package_for_platform "$platform"
}

resolve_fpga_package_output() {
  local platform="$1"
  local flake_ref package

  flake_ref="$(resolve_flake_ref)"
  package="$(resolve_fpga_package_name "$platform")" || return 1
  nix build --no-link --print-out-paths "$flake_ref#$package"
}

resolve_default_fpga_image_from_package() {
  local platform="$1"
  local package_out artifact

  package_out="$(resolve_fpga_package_output "$platform")" || return 1
  artifact="$(default_fpga_artifact_for_platform "$platform")"
  echo "$package_out/bitstreams/$artifact"
}

current_host_name() {
  if [ -n "${COYOTE_HOST_NAME:-}" ]; then
    echo "$COYOTE_HOST_NAME"
    return 0
  fi

  hostname -s 2>/dev/null || hostname
}

default_driver_package_for_target_platform() {
  local host prefix

  host="$(current_host_name)"
  prefix="${COYOTE_NIX_DRIVER_PACKAGE_PREFIX:-coyote-driver}"
  case "$1" in
    versal)
      echo "$prefix-versal-$host"
      ;;
    ultrascale_plus)
      echo "$prefix-ultrascale_plus-$host"
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_driver_package_name() {
  local target_platform="$1"

  if [ -n "${COYOTE_DRIVER_PACKAGE:-}" ]; then
    echo "$COYOTE_DRIVER_PACKAGE"
    return 0
  fi

  if [ -n "${COYOTE_NIX_DRIVER_PACKAGE:-}" ]; then
    echo "$COYOTE_NIX_DRIVER_PACKAGE"
    return 0
  fi

  default_driver_package_for_target_platform "$target_platform"
}

resolve_driver_package_output() {
  local target_platform="$1"
  local flake_ref package

  flake_ref="$(resolve_flake_ref)"
  package="$(resolve_driver_package_name "$target_platform")" || return 1
  nix build --no-link --print-out-paths "$flake_ref#$package"
}

resolve_default_driver_ko_from_package() {
  local target_platform="$1"
  local package_out

  package_out="$(resolve_driver_package_output "$target_platform")" || return 1
  echo "$package_out/coyote_driver.ko"
}

driver_build_hint_for_target_platform() {
  local target_platform="$1"
  local default_driver_package

  default_driver_package="$(resolve_driver_package_name "$target_platform" 2>/dev/null || true)"
  echo "nix build .#${default_driver_package:-coyote-driver-<target-platform>-<host>}"
}

activate_xilinx() {
  local cmd="$1"
  shift || true

  if [ "${COYOTE_NIX_IN_XILINX_DEVSHELL:-0}" = "1" ]; then
    return 0
  fi

  local project_root flake_ref shell_name selector family env_shell_var
  project_root="$(resolve_project_root)"
  flake_ref="."
  if [ -f "$project_root/flake.nix" ]; then
    flake_ref="$project_root"
  fi

  selector="${COYOTE_NIX_PLATFORM:-${FDEV_NAME:-}}"
  family="$(coyote_nix_platform_family "$selector" 2>/dev/null || echo ultrascale)"
  env_shell_var="COYOTE_NIX_${family^^}_DEVSHELL"
  shell_name="${COYOTE_NIX_XILINX_DEVSHELL:-}"
  if [ -z "$shell_name" ]; then
    shell_name="${!env_shell_var:-$family}"
  fi

  exec nix develop "$flake_ref#$shell_name" -c env COYOTE_NIX_IN_XILINX_DEVSHELL=1 "$cmd" "$@"
}
