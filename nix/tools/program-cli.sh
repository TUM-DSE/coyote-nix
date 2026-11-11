usage() {
  echo "Usage: program-cli image.bit|image.pdi" >&2
  echo "Program an FPGA image with Vivado. Pass an image path explicitly, or set FPGA_BITSTREAM." >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if [ $# -gt 1 ]; then
  usage
  exit 1
fi

activate_xilinx program-cli "$@"

project_root="$(resolve_project_root)"
platform="${FDEV_NAME:-u280}"
image="${1:-${FPGA_BITSTREAM:-}}"

if [ -z "$image" ]; then
  echo "ERROR: program-cli requires an explicit image path or FPGA_BITSTREAM." >&2
  usage
  exit 1
fi

# Images may be given relative to the project root.
if [ ! -f "$image" ] && [ -f "$project_root/$image" ]; then
  image="$project_root/$image"
fi

# Programming itself, including hw_server ownership and locking, is done by
# fpga-nix. Coyote keeps its platform-based port default and lock location.
hw_server_port="$(coyote_nix_hw_server_port)"
lock_platform="${platform//[^a-zA-Z0-9_.-]/_}"
export FPGA_NIX_HW_SERVER_PORT="$hw_server_port"
default_lock="/tmp/coyote-program-cli-$lock_platform-$hw_server_port.lock"
export FPGA_NIX_PROGRAM_LOCK_DIR="${COYOTE_NIX_PROGRAM_LOCK_DIR:-$default_lock}"
export FPGA_NIX_BUILD_ROOT="${COYOTE_NIX_BUILD_ROOT:-$project_root/.build}"

exec program-fpga "$image"
