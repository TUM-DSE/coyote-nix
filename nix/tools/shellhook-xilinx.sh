# shellcheck source=/dev/null
source "@XILINX_WRAPPER_LIB@"

export COYOTE_NIX_IN_XILINX_DEVSHELL=1
coyote_nix_export_wrapper_env

coyote_nix_export_gmake_compat

if version="$(coyote_nix_pick_xilinx_version 2>/dev/null || true)"; then
  if [ -n "$version" ]; then
    export COYOTE_NIX_XILINX_VERSION_ACTIVE="$version"
  fi
fi

for tool in vivado hw_server; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required Xilinx wrapper missing from PATH: $tool" >&2
    exit 1
  fi
done

if ! check-xilinx-env >/dev/null 2>&1; then
  if ! command -v xilinx-shell >/dev/null 2>&1; then
    echo "ERROR: cannot enter Xilinx env because xilinx-shell is not available." >&2
    exit 1
  fi
fi
