usage() {
  echo "Usage: check-xilinx-env" >&2
  echo "Print basic Coyote/Xilinx environment diagnostics." >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if [ $# -gt 0 ]; then
  usage
  exit 1
fi

project_root="$(resolve_project_root)"
echo "Project root: $project_root"
echo "Coyote root (flake input): $COYOTE_ROOT"

echo
echo "== Hugepages =="
grep -E 'HugePages_Total|HugePages_Free|Hugepagesize' /proc/meminfo || true

echo
echo "== Xilinx PCIe devices =="
lspci | grep -Ei 'xilinx|processing accelerators|903f|50b4|500c|500d' || echo "No Xilinx FPGA found via lspci"

echo
echo "== Toolchain =="
missing=0

if command -v vivado >/dev/null 2>&1; then
  vivado -version | head -n 1
else
  echo "vivado: not in PATH" >&2
  missing=1
fi

if command -v vitis_hls >/dev/null 2>&1; then
  vitis_hls -version 2>/dev/null | head -n 1 || true
else
  echo "vitis_hls: not in PATH (optional)" >&2
fi

cmake --version | head -n 1
make --version | head -n 1

if [ "$missing" -ne 0 ]; then
  exit 1
fi
