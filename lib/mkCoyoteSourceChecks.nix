{
  pkgs,
  coyoteRoot,
}:

let
  python = pkgs.python3.withPackages (ps: [ ps.jinja2 ]);
  fakeXilinxTools = pkgs.runCommand "coyote-source-check-fake-xilinx-tools" { } ''
    mkdir -p "$out/bin"
    for tool in vivado xsc vitis_hls; do
      cat > "$out/bin/$tool" <<'EOF'
    #!${pkgs.runtimeShell}
    exit 0
    EOF
      chmod +x "$out/bin/$tool"
    done
  '';

  renderContract =
    pkgs.runCommand "coyote-resident-service-control-render-contract"
      {
        nativeBuildInputs = [
          pkgs.cmake
          pkgs.gnumake
          pkgs.stdenv.cc
          python
          fakeXilinxTools
        ];
      }
      ''
        set -euo pipefail
        fixture=${coyoteRoot}/tests/resident_service_control

        render_case() {
          name="$1"
          board="$2"
          shift 2
          build="$TMPDIR/$name"
          cmake -S "$fixture" -B "$build" \
            -DCYT_DIR=${coyoteRoot} \
            -DFDEV_NAME:STRING="$board" \
            -DBUILD_APP:STRING=0 \
            -DBUILD_STATIC:STRING=0 \
            -DBUILD_SHELL:STRING=1 \
            -DSTATIC_PATH=${coyoteRoot}/hw/checkpoints \
            "$@"
          mkdir -p \
            "$build/coyote-resident-service-control-fixture_shell/hdl" \
            "$build/coyote-resident-service-control-fixture_shell/xdc"
          (cd "$build" && ${python}/bin/python write_hdl.py 1 0 0)
        }

        render_case control-u280 u280 \
          -DTEST_ENABLE_SERVICE:BOOL=ON \
          -DTEST_ENABLE_CONTROL:BOOL=ON \
          -DEN_UCLK:STRING=1
        render_case control-v80 v80 \
          -DTEST_ENABLE_SERVICE:BOOL=ON \
          -DTEST_ENABLE_CONTROL:BOOL=ON
        render_case slot-status-u280 u280 \
          -DTEST_ENABLE_SERVICE:BOOL=ON \
          -DTEST_ENABLE_CONTROL:BOOL=ON \
          -DTEST_ENABLE_SLOT_STATUS:BOOL=ON \
          -DTEST_N_REGIONS:STRING=2
        render_case stream-only-u280 u280 \
          -DTEST_ENABLE_SERVICE:BOOL=ON \
          -DTEST_ENABLE_CONTROL:BOOL=OFF
        render_case no-service-v80 v80 \
          -DTEST_ENABLE_SERVICE:BOOL=OFF \
          -DTEST_ENABLE_CONTROL:BOOL=OFF

        for build in "$TMPDIR/control-u280" "$TMPDIR/control-v80"; do
          grep -q 'axil_address_splitter' \
            "$build/coyote-resident-service-control-fixture_shell/hdl/shell_top.sv"
          grep -q 's_axi_service_ctrl' \
            "$build/coyote-resident-service-control-fixture_shell/hdl/dynamic_top.sv"
          grep -q 's_axi_ctrl(s_axi_service_ctrl)' \
            "$build/coyote-resident-service-control-fixture_shell/hdl/dynamic_top.sv"
          grep -q 'set(EN_EXTERNAL_DYNAMIC_SERVICE_CONTROL 1)' "$build/export.cmake"
          grep -q 'set(EXTERNAL_DYNAMIC_SERVICE_CONTROL_ABI "fixture-control-v1")' \
            "$build/export.cmake"
          grep -q 'set(EXTERNAL_DYNAMIC_SERVICE_CONTROL_BASE 4096)' "$build/export.cmake"
          grep -q 'set(EXTERNAL_DYNAMIC_SERVICE_CONTROL_BYTES 4096)' "$build/export.cmake"
        done

        grep -q 'inst_service_control_ccross' \
          "$TMPDIR/control-u280/coyote-resident-service-control-fixture_shell/hdl/shell_top.sv"
        grep -q 's_slot_decoupled(decouple_uclk)' \
          "$TMPDIR/slot-status-u280/coyote-resident-service-control-fixture_shell/hdl/dynamic_top.sv"
        grep -q 'set(EN_EXTERNAL_DYNAMIC_SERVICE_SLOT_STATUS 1)' \
          "$TMPDIR/slot-status-u280/export.cmake"
        grep -q 'set(N_REGIONS 2)' "$TMPDIR/slot-status-u280/export.cmake"
        ! grep -q 's_slot_decoupled' \
          "$TMPDIR/control-u280/coyote-resident-service-control-fixture_shell/hdl/dynamic_top.sv"
        ! grep -q 's_axi_service_ctrl' \
          "$TMPDIR/stream-only-u280/coyote-resident-service-control-fixture_shell/hdl/dynamic_top.sv"
        ! grep -q 'axil_address_splitter' \
          "$TMPDIR/stream-only-u280/coyote-resident-service-control-fixture_shell/hdl/shell_top.sv"
        ! grep -q 'inst_external_dynamic_service' \
          "$TMPDIR/no-service-v80/coyote-resident-service-control-fixture_shell/hdl/dynamic_top.sv"

        if cmake -S "$fixture" -B "$TMPDIR/malformed-control-abi" \
          -DCYT_DIR=${coyoteRoot} \
          -DFDEV_NAME:STRING=u280 \
          -DBUILD_APP:STRING=0 \
          -DBUILD_STATIC:STRING=0 \
          -DBUILD_SHELL:STRING=1 \
          -DSTATIC_PATH=${coyoteRoot}/hw/checkpoints \
          -DTEST_ENABLE_SERVICE:BOOL=ON \
          -DTEST_ENABLE_CONTROL:BOOL=ON \
          -DTEST_CONTROL_ABI:STRING=invalid/control; then
          echo 'malformed CONTROL_ABI unexpectedly configured' >&2
          exit 1
        fi

        touch "$out"
      '';

  splitterSimulation =
    pkgs.runCommand "coyote-axil-address-splitter-simulation"
      {
        nativeBuildInputs = [
          pkgs.stdenv.cc
          pkgs.python3
          pkgs.verilator
        ];
      }
      ''
        set -euo pipefail
        verilator --binary --timing --top-module tb -Wno-fatal -Wno-MULTIDRIVEN \
          -I${coyoteRoot}/hw/hdl/pkg \
          ${coyoteRoot}/hw/tests/axil_splitter_test_pkg.sv \
          ${coyoteRoot}/hw/hdl/pkg/axi_intf.sv \
          ${coyoteRoot}/hw/hdl/common/axil_address_splitter.sv \
          ${coyoteRoot}/hw/tests/axil_address_splitter_tb.sv
        ./obj_dir/Vtb
        touch "$out"
      '';

  hostApiCompile =
    pkgs.runCommand "coyote-resident-service-control-host-api-compile"
      {
        nativeBuildInputs = [ pkgs.stdenv.cc ];
      }
      ''
        set -euo pipefail
        cat > contract.cpp <<'EOF'
        #include <coyote/cResidentServiceControl.hpp>
        static_assert(sizeof(coyote::cyt_service_ctrl_op) == 16);
        static_assert(sizeof(coyote::cyt_service_ctrl_batch) == 1032);
        int main() { return 0; }
        EOF
        c++ -std=c++17 -Wall -Wextra -I${coyoteRoot}/sw/include \
          -c ${coyoteRoot}/sw/src/cResidentServiceControl.cpp -o control.o
        c++ -std=c++17 -Wall -Wextra -I${coyoteRoot}/sw/include \
          contract.cpp control.o -o contract
        ./contract
        touch "$out"
      '';
in
{
  inherit hostApiCompile renderContract splitterSimulation;
}
