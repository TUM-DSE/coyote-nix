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

  coprocessorRenderContract =
    pkgs.runCommand "coyote-coprocessor-render-contract"
      {
        nativeBuildInputs = [
          pkgs.cmake
          pkgs.gnumake
          pkgs.stdenv.cc
          pkgs.verible
          python
          fakeXilinxTools
        ];
      }
      ''
        set -euo pipefail
        fixture=${coyoteRoot}/tests/coprocessor_ports

        render_case() {
          name="$1"
          board="$2"
          ports="$3"
          providers="$4"
          build="$TMPDIR/$name"
          cmake -S "$fixture" -B "$build" \
            -DCYT_DIR=${coyoteRoot} \
            -DFDEV_NAME:STRING="$board" \
            -DBUILD_APP:STRING=0 \
            -DBUILD_STATIC:STRING=0 \
            -DBUILD_SHELL:STRING=1 \
            -DSTATIC_PATH=${coyoteRoot}/hw/checkpoints \
            -DTEST_N_COPROCESSOR_PORTS:STRING="$ports" \
            -DTEST_REGISTER_PROVIDERS:BOOL="$providers"
          mkdir -p \
            "$build/coyote-coprocessor-port-fixture_shell/hdl" \
            "$build/coyote-coprocessor-port-fixture_shell/xdc"
          (cd "$build" && ${python}/bin/python write_hdl.py 1 0 0)
        }

        render_case one-u280 u280 1 OFF
        render_case two-u280 u280 2 OFF
        render_case one-v80 v80 1 ON
        render_case two-v80 v80 2 ON
        render_case disabled-v80 v80 0 OFF

        app_build="$TMPDIR/app-u280"
        cmake -S "$fixture" -B "$app_build" \
          -DCYT_DIR=${coyoteRoot} \
          -DFDEV_NAME:STRING=u280 \
          -DBUILD_APP:STRING=1 \
          -DBUILD_STATIC:STRING=0 \
          -DBUILD_SHELL:STRING=0 \
          -DSHELL_PATH:STRING="$TMPDIR/one-u280" \
          -DTEST_REGISTER_PROVIDERS:BOOL=OFF
        mkdir -p \
          "$app_build/coyote-coprocessor-port-fixture_config_0/user_c0_0/hdl/wrappers" \
          "$app_build/coyote-coprocessor-port-fixture_config_0/user_c0_0/xdc"
        (cd "$app_build" && ${python}/bin/python write_hdl.py 2 0 0)

        app_v80="$TMPDIR/app-v80"
        cmake -S "$fixture" -B "$app_v80" \
          -DCYT_DIR=${coyoteRoot} \
          -DFDEV_NAME:STRING=v80 \
          -DBUILD_APP:STRING=1 \
          -DBUILD_STATIC:STRING=0 \
          -DBUILD_SHELL:STRING=0 \
          -DSHELL_PATH:STRING="$TMPDIR/two-v80" \
          -DTEST_N_COPROCESSOR_PORTS:STRING=2 \
          -DTEST_REGISTER_PROVIDERS:BOOL=OFF
        mkdir -p \
          "$app_v80/coyote-coprocessor-port-fixture_config_0/user_c0_0/hdl/wrappers" \
          "$app_v80/coyote-coprocessor-port-fixture_config_0/user_c0_0/xdc"
        (cd "$app_v80" && ${python}/bin/python write_hdl.py 2 0 0)

        combined="$TMPDIR/combined-service-u280"
        cmake -S ${coyoteRoot}/tests/resident_service_control -B "$combined" \
          -DCYT_DIR=${coyoteRoot} \
          -DFDEV_NAME:STRING=u280 \
          -DBUILD_APP:STRING=0 \
          -DBUILD_STATIC:STRING=0 \
          -DBUILD_SHELL:STRING=1 \
          -DSTATIC_PATH=${coyoteRoot}/hw/checkpoints \
          -DN_COPROCESSOR_PORTS:STRING=1 \
          -DTEST_ENABLE_SERVICE:BOOL=ON \
          -DTEST_ENABLE_CONTROL:BOOL=ON
        mkdir -p \
          "$combined/coyote-resident-service-control-fixture_shell/hdl" \
          "$combined/coyote-resident-service-control-fixture_shell/xdc"
        (cd "$combined" && ${python}/bin/python write_hdl.py 1 0 0)

        for build in one-u280 two-u280 one-v80 two-v80; do
          root="$TMPDIR/$build"
          grep -q 'N_COPROCESSOR_PORTS' "$root/coyote-coprocessor-port-fixture_shell/hdl/lynx_pkg.sv"
          grep -q 'coprocessor_0_recv_tdata' "$root/coyote-coprocessor-port-fixture_shell/hdl/user_wrapper_c0_0.sv"
          grep -q 'coprocessor_0_mmio_awaddr' "$root/coyote-coprocessor-port-fixture_shell/hdl/user_wrapper_c0_0.sv"
          grep -q 'axis_coprocessor_recv' "$root/coyote-coprocessor-port-fixture_shell/hdl/dynamic_top.sv"
          grep -q 'set(COPROCESSOR_INTERFACE_VERSION 1)' "$root/export.cmake"
          grep -q 'set(COPROCESSOR_STREAM_DATA_BITS 512)' "$root/export.cmake"
          grep -q 'set(COPROCESSOR_MMIO_DATA_BITS 64)' "$root/export.cmake"
          ! grep -qi 'r5\|a72' "$root/coyote-coprocessor-port-fixture_shell/hdl/user_wrapper_c0_0.sv"
          verible-verilog-syntax \
            "$root/coyote-coprocessor-port-fixture_shell/hdl/user_wrapper_c0_0.sv" \
            "$root/coyote-coprocessor-port-fixture_shell/hdl/dynamic_top.sv"
        done

        app_root="$app_build/coyote-coprocessor-port-fixture_config_0/user_c0_0/hdl"
        grep -q 'axis_coprocessor_recv' "$app_root/wrappers/user_wrapper_c0_0.sv"
        grep -q 's_axi_coprocessor_mmio' "$app_root/wrappers/user_wrapper_c0_0.sv"
        grep -q 'axis_coprocessor_recv' "$app_root/wrappers/user_logic_c0_0.sv"
        verible-verilog-syntax \
          "$app_root/wrappers/user_wrapper_c0_0.sv" \
          "$app_root/wrappers/user_logic_c0_0.sv"
        grep -q 'coprocessor_1_recv_tdata' \
          "$app_v80/coyote-coprocessor-port-fixture_config_0/user_c0_0/hdl/wrappers/user_wrapper_c0_0.sv"
        grep -q 'inst_external_dynamic_service' \
          "$combined/coyote-resident-service-control-fixture_shell/hdl/dynamic_top.sv"
        grep -q 'axis_coprocessor_recv' \
          "$combined/coyote-resident-service-control-fixture_shell/hdl/dynamic_top.sv"

        cp -r "$TMPDIR/one-u280" "$TMPDIR/incomplete-shell"
        sed -i '/COPROCESSOR_/d;/N_COPROCESSOR_PORTS/d' "$TMPDIR/incomplete-shell/export.cmake"
        if cmake -S "$fixture" -B "$TMPDIR/incomplete-contract-app" \
          -DCYT_DIR=${coyoteRoot} \
          -DFDEV_NAME:STRING=u280 \
          -DBUILD_APP:STRING=1 \
          -DBUILD_STATIC:STRING=0 \
          -DBUILD_SHELL:STRING=0 \
          -DSHELL_PATH:STRING="$TMPDIR/incomplete-shell" \
          -DTEST_N_COPROCESSOR_PORTS:STRING=1; then
          echo 'application unexpectedly accepted incomplete co-processor shell contract' >&2
          exit 1
        fi

        cp -r "$TMPDIR/one-u280" "$TMPDIR/wrong-width-shell"
        sed -i 's/set(COPROCESSOR_STREAM_DATA_BITS 512)/set(COPROCESSOR_STREAM_DATA_BITS 256)/' \
          "$TMPDIR/wrong-width-shell/export.cmake"
        if cmake -S "$fixture" -B "$TMPDIR/wrong-width-app" \
          -DCYT_DIR=${coyoteRoot} \
          -DFDEV_NAME:STRING=u280 \
          -DBUILD_APP:STRING=1 \
          -DBUILD_STATIC:STRING=0 \
          -DBUILD_SHELL:STRING=0 \
          -DSHELL_PATH:STRING="$TMPDIR/wrong-width-shell" \
          -DTEST_N_COPROCESSOR_PORTS:STRING=1; then
          echo 'application unexpectedly accepted incompatible co-processor width' >&2
          exit 1
        fi

        if cmake -S "$fixture" -B "$TMPDIR/incompatible-app" \
          -DCYT_DIR=${coyoteRoot} \
          -DFDEV_NAME:STRING=u280 \
          -DBUILD_APP:STRING=1 \
          -DBUILD_STATIC:STRING=0 \
          -DBUILD_SHELL:STRING=0 \
          -DSHELL_PATH:STRING="$TMPDIR/one-u280" \
          -DTEST_N_COPROCESSOR_PORTS:STRING=2; then
          echo 'application requiring too many co-processor ports unexpectedly configured' >&2
          exit 1
        fi

        test "$(grep -c 'provider to application stream' "$TMPDIR/one-u280/coyote-coprocessor-port-fixture_shell/hdl/user_wrapper_c0_0.sv")" -eq 1
        test "$(grep -c 'provider to application stream' "$TMPDIR/two-u280/coyote-coprocessor-port-fixture_shell/hdl/user_wrapper_c0_0.sv")" -eq 2
        grep -q 'set(COPROCESSOR_PROVIDER_COUNT 2)' "$TMPDIR/one-v80/export.cmake"
        grep -q '1|mock-r5|r5|baremetal|fixture-runtime|1|1' "$TMPDIR/one-v80/export.cmake"
        grep -q '2|mock-a72|a72|baremetal|fixture-runtime|1|1' "$TMPDIR/one-v80/export.cmake"

        ! grep -q 'COPROCESSOR_' "$TMPDIR/disabled-v80/export.cmake"
        ! grep -q 'axis_coprocessor' \
          "$TMPDIR/disabled-v80/coyote-coprocessor-port-fixture_shell/hdl/user_wrapper_c0_0.sv"

        if cmake -S "$fixture" -B "$TMPDIR/duplicate-endpoint" \
          -DCYT_DIR=${coyoteRoot} \
          -DFDEV_NAME:STRING=v80 \
          -DBUILD_APP:STRING=0 \
          -DBUILD_STATIC:STRING=0 \
          -DBUILD_SHELL:STRING=1 \
          -DSTATIC_PATH=${coyoteRoot}/hw/checkpoints \
          -DTEST_N_COPROCESSOR_PORTS:STRING=1 \
          -DTEST_REGISTER_PROVIDERS:BOOL=ON \
          -DTEST_DUPLICATE_ENDPOINT:BOOL=ON; then
          echo 'duplicate co-processor endpoint unexpectedly configured' >&2
          exit 1
        fi

        touch "$out"
      '';

  coprocessorSimulation =
    pkgs.runCommand "coyote-coprocessor-port-gateway-simulation"
      {
        nativeBuildInputs = [
          pkgs.stdenv.cc
          pkgs.python3
          pkgs.verilator
        ];
      }
      ''
        set -euo pipefail
        verilator --binary --timing --assert --top-module coprocessor_port_gateway_tb -Wall -Wno-fatal \
          ${coyoteRoot}/hw/hdl/coprocessor/coprocessor_port_gateway.sv \
          ${coyoteRoot}/hw/tests/coprocessor_port_gateway_tb.sv
        ./obj_dir/Vcoprocessor_port_gateway_tb
        touch "$out"
      '';

  coprocessorHostApi =
    pkgs.runCommand "coyote-coprocessor-host-api"
      {
        nativeBuildInputs = [ pkgs.stdenv.cc ];
      }
      ''
        set -euo pipefail
        c++ -std=c++17 -Wall -Wextra -Werror \
          -I${coyoteRoot}/sw/include \
          ${coyoteRoot}/sw/src/cCoprocessor.cpp \
          ${coyoteRoot}/tests/coprocessor_ports/model_test.cpp \
          -o coprocessor-model-test
        ./coprocessor-model-test
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
  inherit
    coprocessorHostApi
    coprocessorRenderContract
    coprocessorSimulation
    hostApiCompile
    renderContract
    splitterSimulation
    ;
}
