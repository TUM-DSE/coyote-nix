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

normalize_cmake_boolean() {
  local value=${1^^}

  case "$value" in
    "" | 0 | OFF | NO | FALSE | N | IGNORE | NOTFOUND | *-NOTFOUND)
      printf '0\n'
      ;;
    *)
      printf '1\n'
      ;;
  esac
}

resolve_timing_check_policy() {
  local flag raw_value="" found=0

  unset COYOTE_NIX_EN_TIMING_CHECK
  for flag in "${cmake_extra_flags[@]}"; do
    if [[ "$flag" =~ ^-DEN_TIMING_CHECK(:[^=]+)?=(.*)$ ]]; then
      raw_value=${BASH_REMATCH[2]}
      found=1
    fi
  done

  if [ "$found" = 1 ]; then
    COYOTE_NIX_EN_TIMING_CHECK=$(normalize_cmake_boolean "$raw_value")
    export COYOTE_NIX_EN_TIMING_CHECK
  fi
}

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
    -DCMAKE_POLICY_VERSION_MINIMUM=3.10 \
    -DCMAKE_POLICY_DEFAULT_CMP0167=OLD \
    "${cmake_extra_flags[@]}" \
    -DCOMP_CORES="$comp_cores"
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
  local cache_count cache_value generated_count

  if [ ! -f base.tcl ]; then
    if [ -n "${COYOTE_NIX_EN_TIMING_CHECK+x}" ]; then
      echo "ERROR: explicit EN_TIMING_CHECK policy has no generated base.tcl" >&2
      exit 1
    fi
    return 0
  fi

  # shellcheck disable=SC2016
  sed -i 's|^set device_ip_dir   "\$ip_dir/dev"$|set device_ip_dir   "\$build_dir/ip/dev"|' base.tcl

  if [ -z "${COYOTE_NIX_EN_TIMING_CHECK+x}" ]; then
    return 0
  fi

  cache_count=$(grep -Ec '^EN_TIMING_CHECK:[^=]+=' CMakeCache.txt || true)
  if [ "$cache_count" -ne 1 ]; then
    echo "ERROR: explicit EN_TIMING_CHECK policy is not represented exactly once in CMakeCache.txt" >&2
    exit 1
  fi
  cache_value=$(sed -nE 's/^EN_TIMING_CHECK:[^=]+=(.*)$/\1/p' CMakeCache.txt)
  if [ "$(normalize_cmake_boolean "$cache_value")" != "$COYOTE_NIX_EN_TIMING_CHECK" ]; then
    echo "ERROR: configured EN_TIMING_CHECK policy differs from the requested package policy" >&2
    exit 1
  fi

  generated_count=$(grep -Ec '^[[:space:]]*set[[:space:]]+cfg\(en_timing_check\)[[:space:]]+' base.tcl || true)
  if [ "$generated_count" -ne 1 ]; then
    echo "ERROR: generated base.tcl must assign cfg(en_timing_check) exactly once" >&2
    exit 1
  fi
  sed -E -i \
    "s|^([[:space:]]*set[[:space:]]+cfg\\(en_timing_check\\)[[:space:]]+)[^[:space:]#]+|\\1$COYOTE_NIX_EN_TIMING_CHECK|" \
    base.tcl
  if ! grep -Eq \
    "^[[:space:]]*set[[:space:]]+cfg\\(en_timing_check\\)[[:space:]]+$COYOTE_NIX_EN_TIMING_CHECK([[:space:]]|$)" \
    base.tcl; then
    echo "ERROR: failed to propagate EN_TIMING_CHECK into generated base.tcl" >&2
    exit 1
  fi
}

run_shell_fragment() {
  local fragment="$1"

  if [ -s "$fragment" ]; then
    # shellcheck disable=SC1090
    . "$fragment"
  fi
}

run_measured_build_commands() {
  local command_status scratch_bytes time_file

  mkdir -p "$build_dir/logs" "$build_dir/metadata"
  time_file="$build_dir/metadata/gnu-time.txt"
  : > "$build_dir/logs/command.stdout.log"
  : > "$build_dir/logs/command.stderr.log"

  set +e
  "$COYOTE_NIX_TIME" \
    --output="$time_file" \
    --format='wallSeconds=%e\nuserCpuSeconds=%U\nsystemCpuSeconds=%S\nmaxRssKiB=%M\nexitCode=%x' \
    bash -euo pipefail "$build_commands" \
    > >(tee "$build_dir/logs/command.stdout.log") \
    2> >(tee "$build_dir/logs/command.stderr.log" >&2)
  command_status=$?
  wait
  set -e

  scratch_bytes="$(du -sb "$build_dir" | cut -f1)"
  jq -Rn \
    --arg scope build-commands \
    --argjson requestedCores "${COYOTE_NIX_HW_CORES}" \
    --argjson scratchBytes "$scratch_bytes" \
    --argjson observedExitCode "$command_status" \
    --rawfile measured "$time_file" \
    '
      ($measured | split("\n") | map(select(length > 0) | split("=") | {(.[0]): .[1]}) | add) as $m
      | {
          schemaVersion: 1,
          kind: "coyote-stage-execution",
          measurementScope: $scope,
          status: (if $observedExitCode == 0 then "completed" else "failed" end),
          exitCode: $observedExitCode,
          wallSeconds: $m.wallSeconds,
          userCpuSeconds: $m.userCpuSeconds,
          systemCpuSeconds: $m.systemCpuSeconds,
          maxRssKiB: ($m.maxRssKiB | tonumber),
          requestedCores: $requestedCores,
          scratchBytesAfterCommand: $scratchBytes
        }
    ' > "$build_dir/metadata/execution.json"

  if [ -f "$build_dir/metadata/primary-tool.json" ]; then
    jq --slurpfile primary "$build_dir/metadata/primary-tool.json" \
      '. + { primaryTool: $primary[0] }' \
      "$build_dir/metadata/execution.json" \
      > "$build_dir/metadata/execution.json.tmp"
    mv "$build_dir/metadata/execution.json.tmp" "$build_dir/metadata/execution.json"
  fi

  if [ "$command_status" -ne 0 ]; then
    return "$command_status"
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

resolve_timing_check_policy
setup_build_environment
configure_build
patch_sim_dpi_link
patch_base_tcl
run_shell_fragment "$pre_build_setup"
run_measured_build_commands
if [ "${COYOTE_NIX_CHECK_TIMING_LOG:-1}" = 1 ]; then
  check_timing_constraints
fi
check_expected_artifacts
