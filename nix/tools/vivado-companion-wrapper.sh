set -euo pipefail

# shellcheck source=/dev/null
source "@XILINX_WRAPPER_LIB@"

tool_name="$(basename "$0")"

version="$(coyote_nix_pick_xilinx_version_for coyote_nix_find_vivado_bin 2>/dev/null || true)"
if [ -z "$version" ]; then
  echo "$tool_name not found under $(coyote_nix_xilinx_share_root)" >&2
  exit 1
fi

vivado_bin="$(coyote_nix_find_vivado_bin "$version" 2>/dev/null || true)"
if [ -z "$vivado_bin" ]; then
  echo "Vivado $version not found under $(coyote_nix_xilinx_share_root)" >&2
  exit 1
fi

vivado_root="$(dirname "$(dirname "$vivado_bin")")"
tool_bin="$vivado_root/bin/$tool_name"
if [ ! -x "$tool_bin" ]; then
  echo "$tool_name not found for Vivado $version under $(coyote_nix_xilinx_share_root)" >&2
  exit 1
fi

coyote_nix_exec_xilinx_tool "$version" "$tool_bin" "$@"
