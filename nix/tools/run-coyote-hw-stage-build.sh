#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <src> <build-dir> <pre-build-setup> <build-commands> <expected-paths> [cmake-flag ...]" >&2
  exit 2
}

if [ "$#" -lt 5 ]; then
  usage
fi

src="$1"
build_dir="$2"
pre_build_setup="$3"
build_commands="$4"
expected_paths="$5"
shift 5
cmake_extra_flags=("$@")

setup_build_environment() {
  export HOME="$build_dir/.home"
  mkdir -p "$HOME"
  export TERM="${TERM:-xterm-256color}"
}

configure_build() {
  local comp_cores

  mkdir -p "$build_dir"
  cd "$build_dir"

  comp_cores="${COYOTE_NIX_HW_CORES:-$(nproc)}"
  cmake "$src" \
    -DFDEV_NAME="$FDEV_NAME" \
    -DCOMP_CORES="$comp_cores" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.10 \
    -DCMAKE_POLICY_DEFAULT_CMP0167=OLD \
    "${cmake_extra_flags[@]}"
}

resolve_vivado_root() {
  local cand

  for cand in \
    "$COYOTE_NIX_XILINX_SHARE_ROOT/$COYOTE_NIX_XILINX_VERSION/Vivado" \
    "$COYOTE_NIX_XILINX_SHARE_ROOT/Vivado/$COYOTE_NIX_XILINX_VERSION"
  do
    if [ -d "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done

  return 1
}

resolve_xilinx_gxx_lib64() {
  local vivado_root="$1"

  if [ ! -d "$vivado_root/tps/lnx64" ]; then
    return 1
  fi

  find "$vivado_root/tps/lnx64" \
    -maxdepth 2 \
    -type d \
    -path '*/gcc-*/lib64' | sort -V | tail -n1
}

patch_sim_dpi_link() {
  local sim_dpi_makefile vivado_root xilinx_gxx_lib64 sim_kernel_lib sim_systemc_lib sim_dpi_link_script sim_dpi_link_line

  sim_dpi_makefile="$build_dir/dpi/CMakeFiles/sim_dpi_c.dir/build.make"
  if [ ! -f "$sim_dpi_makefile" ]; then
    return 0
  fi

  vivado_root="$(resolve_vivado_root || true)"
  xilinx_gxx_lib64=""
  if [ -n "$vivado_root" ]; then
    xilinx_gxx_lib64="$(resolve_xilinx_gxx_lib64 "$vivado_root" || true)"
  fi

  if [ -z "$vivado_root" ] || [ -z "$xilinx_gxx_lib64" ]; then
    echo "WARNING: could not resolve Vivado host linker runtime; leaving sim DPI link step unpatched" >&2
    return 0
  fi

  if [ -e "$vivado_root/lib/lnx64.o/libxv_simulator_kernel.so" ]; then
    sim_kernel_lib="$vivado_root/lib/lnx64.o/libxv_simulator_kernel.so"
    sim_systemc_lib="$vivado_root/lib/lnx64.o/libxv_xsim_systemc.so"
  else
    sim_kernel_lib="$vivado_root/lib/lnx64.o/librdi_simulator_kernel.so"
    sim_systemc_lib="$vivado_root/lib/lnx64.o/librdi_xsim_systemc.so"
  fi

  sim_dpi_link_script="$build_dir/.nix-sim-dpi-link.sh"
  cat > "$sim_dpi_link_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${CXX:-g++}" -Wa,-W -O -fPIC -m64 -shared -o coyote_sim.so xsim.dir/work/xsc/*.o \
  "$sim_kernel_lib" \
  -L"$xilinx_gxx_lib64" \
  -Wl,--disable-new-dtags \
  -Wl,-rpath="$xilinx_gxx_lib64" \
  -Wl,-rpath="$vivado_root/lib/lnx64.o" \
  -Wl,-rpath="$vivado_root/lib/lnx64.o/Default" \
  "$sim_systemc_lib" \
  -L"$vivado_root/lib/lnx64.o/Default"
EOF
  chmod +x "$sim_dpi_link_script"

  sim_dpi_link_line="$(printf '\tcd %s/sim && %s -c %s' "$build_dir" "${COYOTE_NIX_XILINX_SHELL:-bash}" "$sim_dpi_link_script")"
  gawk \
    -v old_re='^[[:space:]]*cd .*/sim && .*/xsc --shared --output coyote_sim$' \
    -v new_line="$sim_dpi_link_line" \
    '{ if ($0 ~ old_re) print new_line; else print }' \
    "$sim_dpi_makefile" > "$sim_dpi_makefile.tmp"
  mv "$sim_dpi_makefile.tmp" "$sim_dpi_makefile"
}

patch_base_tcl() {
  if [ -f base.tcl ]; then
    # shellcheck disable=SC2016
    sed -i 's|^set device_ip_dir   "\$ip_dir/dev"$|set device_ip_dir   "\$build_dir/ip/dev"|' base.tcl
  fi
}

run_shell_fragment() {
  local fragment="$1"

  if [ -s "$fragment" ]; then
    # shellcheck disable=SC1090
    . "$fragment"
  fi
}

check_timing_constraints() {
  if [ -f "$build_dir/vivado.log" ] && \
    grep -Pe '\d+ constraint not met\.|Timing constraints are not met\.' "$build_dir/vivado.log" >/dev/null; then
    echo "ERROR: timing constraints not met; see $build_dir/vivado.log" >&2
    exit 1
  fi
}

check_expected_artifacts() {
  local relpath

  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    if [ ! -e "$build_dir/$relpath" ]; then
      echo "ERROR: missing expected build artifact: $build_dir/$relpath" >&2
      exit 1
    fi
  done < "$expected_paths"
}

setup_build_environment
configure_build
patch_sim_dpi_link
patch_base_tcl
run_shell_fragment "$pre_build_setup"
run_shell_fragment "$build_commands"
check_timing_constraints
check_expected_artifacts
