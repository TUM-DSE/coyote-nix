#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source @XILINX_WRAPPER_LIB@

tool_name="$(basename "$0")"
version="$(coyote_nix_pick_xilinx_version_for coyote_nix_resolve_vitis_root_by_version 2>/dev/null || true)"
if [ -z "$version" ]; then
  echo "No complete Vitis installation found for COYOTE_NIX_XILINX_VERSION=${COYOTE_NIX_XILINX_VERSION:-<unset>}" >&2
  exit 1
fi

case "$tool_name" in
  armr5-none-eabi-*)
    tool_bin="$(coyote_nix_find_armr5_bin "$version" "$tool_name" 2>/dev/null || true)"
    ;;
  bootgen)
    tool_bin="$(coyote_nix_find_vitis_bin "$version" bootgen 2>/dev/null || true)"
    ;;
  *)
    echo "Unsupported embedded tool wrapper: $tool_name" >&2
    exit 1
    ;;
esac

if [ -z "$tool_bin" ]; then
  echo "$tool_name not found in Vitis $version" >&2
  exit 1
fi

coyote_nix_exec_xilinx_tool "$version" "$tool_bin" "$@"
