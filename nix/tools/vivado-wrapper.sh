set -euo pipefail

# shellcheck source=/dev/null
source "@XILINX_WRAPPER_LIB@"

case "${1:-}" in
  -h|--help)
    set -- -help "${@:2}"
    ;;
esac

version="$(coyote_nix_pick_xilinx_version_for coyote_nix_find_vivado_bin 2>/dev/null || true)"
if [ -z "$version" ]; then
  echo "Vivado not found under $(coyote_nix_xilinx_share_root)" >&2
  exit 1
fi

vivado_bin="$(coyote_nix_find_vivado_bin "$version" 2>/dev/null || true)"
if [ -z "$vivado_bin" ]; then
  echo "Vivado $version not found under $(coyote_nix_xilinx_share_root)" >&2
  exit 1
fi

coyote_nix_exec_xilinx_tool "$version" "$vivado_bin" "$@"
