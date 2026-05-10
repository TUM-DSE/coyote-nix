set -euo pipefail

# shellcheck source=/dev/null
source "@XILINX_WRAPPER_LIB@"

normalize_args_for_vitis_run() {
  local out=()
  local have_hls_action=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -version)
        out+=("--version")
        ;;
      -help|-h|--help)
        out+=("--help")
        ;;
      -f)
        shift
        if [ "$#" -eq 0 ]; then
          echo "ERROR: vitis_hls -f requires a Tcl file argument" >&2
          return 2
        fi
        out+=("--tcl" "$1")
        have_hls_action=1
        ;;
      *.tcl)
        out+=("--tcl" "$1")
        have_hls_action=1
        ;;
      --tcl|--itcl|--csim|--cosim|--impl|--package)
        out+=("$1")
        have_hls_action=1
        ;;
      *)
        out+=("$1")
        ;;
    esac
    shift
  done

  if [ "$have_hls_action" -eq 0 ]; then
    local a
    for a in "${out[@]}"; do
      if [ "$a" = "--version" ] || [ "$a" = "--help" ]; then
        printf '%s\n' "${out[@]}"
        return 0
      fi
    done
  fi

  printf '%s\n' "${out[@]}"
}

coyote_nix_have_vitis_hls_frontend() {
  coyote_nix_find_vitis_hls_bin "$1" >/dev/null 2>&1 || coyote_nix_find_vitis_run_bin "$1" >/dev/null 2>&1
}

version="$(coyote_nix_pick_xilinx_version_for coyote_nix_have_vitis_hls_frontend 2>/dev/null || true)"
if [ -z "$version" ]; then
  echo "vitis_hls not found under $(coyote_nix_xilinx_share_root)" >&2
  exit 1
fi

hls_bin="$(coyote_nix_find_vitis_hls_bin "$version" 2>/dev/null || true)"
vitis_run_bin="$(coyote_nix_find_vitis_run_bin "$version" 2>/dev/null || true)"
if [ -z "$hls_bin" ] && [ -z "$vitis_run_bin" ]; then
  echo "vitis_hls frontend not found for Xilinx $version under $(coyote_nix_xilinx_share_root)" >&2
  exit 1
fi

if [ -n "$hls_bin" ]; then
  coyote_nix_exec_xilinx_tool "$version" "$hls_bin" "$@"
fi

mapped_args=()
while IFS= read -r x; do
  mapped_args+=("$x")
done < <(normalize_args_for_vitis_run "$@")

q_vitis_run_bin="$(coyote_nix_shell_quote "$vitis_run_bin")"
coyote_nix_exec_xilinx_shell_command "$version" "exec $q_vitis_run_bin --mode hls \"\$@\"" "${mapped_args[@]}"
