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

  routeValidationContract =
    pkgs.runCommand "coyote-routed-flow-validation-contract"
      {
        nativeBuildInputs = [ pkgs.tcl ];
      }
      ''
        set -euo pipefail
        tclsh ${coyoteRoot}/tests/route_validation/template_contract.tcl \
          ${coyoteRoot}/scripts/base.tcl.in \
          ${coyoteRoot}/scripts/impl/pnr_shell.tcl.in \
          ${coyoteRoot}/scripts/impl/physical_stage.tcl.in \
          ${coyoteRoot}/scripts/dyn/flow_app_link.tcl.in \
          ${coyoteRoot}/scripts/dyn/flow_dyn_link_ultrascale_plus.tcl.in \
          ${coyoteRoot}/scripts/dyn/flow_dyn_link_versal.tcl.in \
          ${coyoteRoot}/scripts/dyn/flow_dyn_finalize.tcl.in \
          ${coyoteRoot}/scripts/dyn/flow_app.tcl.in \
          ${coyoteRoot}/scripts/dyn/flow_dyn_ultrascale_plus.tcl.in \
          ${coyoteRoot}/scripts/dyn/flow_dyn_versal.tcl.in \
          ${coyoteRoot}/scripts/impl/bitgen.tcl.in \
          ${coyoteRoot}/cmake/FindCoyoteHW.cmake
        touch "$out"
      '';

  renderContract =
    pkgs.runCommand "coyote-resident-service-control-render-contract"
      {
        nativeBuildInputs = [
          pkgs.cmake
          pkgs.gnumake
          pkgs.stdenv.cc
          pkgs.tcl
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
        render_case peer-u280 u280 \
          -DTEST_ENABLE_SERVICE:BOOL=ON \
          -DTEST_ENABLE_CONTROL:BOOL=ON \
          -DTEST_ENABLE_PEER:BOOL=ON
        render_case stream-only-u280 u280 \
          -DTEST_ENABLE_SERVICE:BOOL=ON \
          -DTEST_ENABLE_CONTROL:BOOL=OFF
        render_case no-service-v80 v80 \
          -DTEST_ENABLE_SERVICE:BOOL=OFF \
          -DTEST_ENABLE_CONTROL:BOOL=OFF

        u280_shell_clock="$TMPDIR/control-u280/coyote-resident-service-control-fixture_shell/xdc/shell_clk.xdc"
        test -f "$u280_shell_clock"
        test "$(grep -Fxc 'set_property CLOCK_BUFFER_TYPE NONE [get_ports dclk]' "$u280_shell_clock")" -eq 1
        if grep -Fq '[get_ports xclk]' "$u280_shell_clock"; then
          echo 'UltraScale+ shell clock constraint targets the wrong PR-boundary port' >&2
          exit 1
        fi

        render_case immutable-v80 v80 \
          -DTEST_ENABLE_SERVICE:BOOL=ON \
          -DTEST_ENABLE_CONTROL:BOOL=ON \
          -DIMMUTABLE_IMPLEMENTATION_STAGES:BOOL=ON \
          -DIMPLEMENTATION_PHASE:STRING=opt \
          -DIMPLEMENTATION_INPUT_DCP:FILEPATH="$TMPDIR/immutable-v80/checkpoints/input.dcp" \
          -DIMPLEMENTATION_OUTPUT_DCP:FILEPATH="$TMPDIR/immutable-v80/checkpoints/output.dcp" \
          -DIMPLEMENTATION_COMPLETION_PATH:FILEPATH="$TMPDIR/immutable-v80/checkpoints/opt_complete" \
          -DIMPLEMENTATION_REPORT_DIR:PATH="$TMPDIR/immutable-v80/reports" \
          -DIMPLEMENTATION_TELEMETRY_PATH:FILEPATH="$TMPDIR/immutable-v80/reports/physical.json"
        cmake --build "$TMPDIR/immutable-v80" --target help \
          > "$TMPDIR/immutable-v80/target-help.txt"
        grep -q '^... physical_stage$' "$TMPDIR/immutable-v80/target-help.txt"
        if grep -Eq '^... (dynamic_link|dynamic_finalize)$' "$TMPDIR/immutable-v80/target-help.txt"; then
          echo 'single physical phase unexpectedly exposes a competing link/finalize producer' >&2
          exit 1
        fi
        if grep -q '^... app$' "$TMPDIR/immutable-v80/target-help.txt"; then
          echo 'immutable build unexpectedly exposes legacy aggregate app target' >&2
          exit 1
        fi
        test -f "$TMPDIR/immutable-v80/physical_stage.tcl"
        grep -F 'set phase "opt"' "$TMPDIR/immutable-v80/physical_stage.tcl" >/dev/null

        if cmake -S "$fixture" -B "$TMPDIR/invalid-immutable-alias" \
          -DCYT_DIR=${coyoteRoot} \
          -DFDEV_NAME:STRING=v80 \
          -DBUILD_APP:STRING=0 \
          -DBUILD_STATIC:STRING=0 \
          -DBUILD_SHELL:STRING=1 \
          -DIMMUTABLE_IMPLEMENTATION_STAGES:BOOL=ON \
          -DIMPLEMENTATION_PHASE:STRING=route \
          -DIMPLEMENTATION_INPUT_DCP:FILEPATH="$TMPDIR/alias.dcp" \
          -DIMPLEMENTATION_OUTPUT_DCP:FILEPATH="$TMPDIR/alias.dcp" \
          -DIMPLEMENTATION_COMPLETION_PATH:FILEPATH="$TMPDIR/complete" \
          -DIMPLEMENTATION_REPORT_DIR:PATH="$TMPDIR/alias-reports" \
          -DIMPLEMENTATION_TELEMETRY_PATH:FILEPATH="$TMPDIR/alias-reports/physical.json"; then
          echo 'aliased immutable input/output unexpectedly configured' >&2
          exit 1
        fi

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
        grep -q 's_axis_peer_recv(s_axis_peer_recv)' \
          "$TMPDIR/peer-u280/coyote-resident-service-control-fixture_shell/hdl/dynamic_top.sv"
        grep -q 'm_axis_peer_send(m_axis_peer_send)' \
          "$TMPDIR/peer-u280/coyote-resident-service-control-fixture_shell/hdl/dynamic_top.sv"
        grep -q 'set(EN_EXTERNAL_DYNAMIC_SERVICE_PEER_ENDPOINTS 1)' \
          "$TMPDIR/peer-u280/export.cmake"
        grep -q 'set(PEER_BACKEND aurora_qsfp1)' \
          "$TMPDIR/peer-u280/export.cmake"
        grep -q 'set(PEER_CONNECTOR QSFP1)' \
          "$TMPDIR/peer-u280/export.cmake"
        grep -q 'set(PEER_FLOW_CONTROL_MODE aurora-immediate-nfc)' \
          "$TMPDIR/peer-u280/export.cmake"
        grep -q 'set(COYOTE_PEER_INTERFACE_VERSION 1)' \
          "$TMPDIR/peer-u280/export.cmake"
        test "$(grep -c 'CONFIG.TDATA_NUM_BYTES        {64}' \
          ${coyoteRoot}/scripts/ip_inst/aurora_infrastructure.tcl)" -eq 2
        grep -q 'CONFIG.flow_mode            {Immediate_NFC}' \
          ${coyoteRoot}/scripts/ip_inst/aurora_infrastructure.tcl
        grep -q 'CONFIG.HAS_PROG_FULL          {1}' \
          ${coyoteRoot}/scripts/ip_inst/aurora_infrastructure.tcl
        grep -q 'aurora_tx_512_to_256 inst_tx_width_adapter' \
          ${coyoteRoot}/hw/hdl/aurora/aurora_module.sv
        grep -q 'aurora_rx_256_to_512 inst_rx_width_adapter' \
          ${coyoteRoot}/hw/hdl/aurora/aurora_module.sv
        grep -q 'else if (rx_pack_overflow)' \
          ${coyoteRoot}/hw/hdl/aurora/aurora_module.sv
        grep -q 'u_transport_fault_init_sync' \
          ${coyoteRoot}/hw/hdl/aurora/aurora_module.sv
        grep -q '!aurora_hard_err && !aurora_mmcm_not_locked' \
          ${coyoteRoot}/hw/hdl/peer/peer_backend_aurora_qsfp1.sv
        ! grep -q 'tx_hi_valid\|rx_out_valid\|rx_have_low' \
          ${coyoteRoot}/hw/hdl/peer/peer_backend_aurora_qsfp1.sv
        grep -q '{CLOCKREGION_X0Y8:CLOCKREGION_X3Y11}' \
          ${coyoteRoot}/scripts/impl/physical_stage.tcl.in
        grep -Fq 'set_property PROCESSING_ORDER LATE [get_files $xdc]' \
          ${coyoteRoot}/scripts/impl/link.tcl.in
        grep -q 'set_property IS_SOFT FALSE' \
          ${coyoteRoot}/scripts/impl/physical_stage.tcl.in
        ! grep -q 'axis_peer_recv_tdata' \
          "$TMPDIR/peer-u280/coyote-resident-service-control-fixture_shell/hdl/dynamic_top.sv"
        ! grep -q 's_slot_decoupled' \
          "$TMPDIR/control-u280/coyote-resident-service-control-fixture_shell/hdl/dynamic_top.sv"
        ! grep -q 's_axi_service_ctrl' \
          "$TMPDIR/stream-only-u280/coyote-resident-service-control-fixture_shell/hdl/dynamic_top.sv"
        ! grep -q 'axil_address_splitter' \
          "$TMPDIR/stream-only-u280/coyote-resident-service-control-fixture_shell/hdl/shell_top.sv"
        ! grep -q 'inst_external_dynamic_service' \
          "$TMPDIR/no-service-v80/coyote-resident-service-control-fixture_shell/hdl/dynamic_top.sv"

        for build in "$TMPDIR/control-u280" "$TMPDIR/control-v80"; do
          cmake --build "$build" --target help > "$build/target-help.txt"
          cmake --build "$build" --target project
          test -f "$build/.coyote_project.stamp"
          test -f "$build/synthesis_analysis.tcl"
          grep -q 'shell_synthesis_checkpoint' "$build/target-help.txt"
          grep -q 'synthesis_analysis' "$build/target-help.txt"
          ${pkgs.tcl}/bin/tclsh \
            ${coyoteRoot}/tests/synthesis_analysis/template_contract.tcl \
            "$build/synthesis_analysis.tcl"
          grep -q 'set cfg(synthesis_analysis_max_paths) 100' "$build/base.tcl"
          grep -q 'set cfg(synthesis_analysis_max_fanout_nets) 100' "$build/base.tcl"

          test -f "$build/timing_oracle.tcl"
          grep -q 'timing_oracle' "$build/target-help.txt"
          ${pkgs.tcl}/bin/tclsh \
            ${coyoteRoot}/tests/timing_oracle/template_contract.tcl \
            "$build/timing_oracle.tcl"
          grep -q 'set cfg(timing_oracle_reject_rqa_below) 3' "$build/base.tcl"
          grep -q 'set cfg(timing_oracle_pass_rqa_at_least) 4' "$build/base.tcl"
          grep -q 'set cfg(timing_oracle_max_paths) 100' "$build/base.tcl"
          grep -q 'set(TIMING_ORACLE_REJECT_RQA_BELOW 3)' "$build/export.cmake"
          grep -q 'set(TIMING_ORACLE_PASS_RQA_AT_LEAST 4)' "$build/export.cmake"
          grep -q 'set(TIMING_ORACLE_MAX_PATHS 100)' "$build/export.cmake"
        done

        if cmake -S "$fixture" -B "$TMPDIR/invalid-synthesis-analysis-policy" \
          -DCYT_DIR=${coyoteRoot} \
          -DFDEV_NAME:STRING=v80 \
          -DBUILD_APP:STRING=0 \
          -DBUILD_STATIC:STRING=0 \
          -DBUILD_SHELL:STRING=1 \
          -DSTATIC_PATH=${coyoteRoot}/hw/checkpoints \
          -DSYNTHESIS_ANALYSIS_MAX_PATHS:STRING=0; then
          echo 'invalid synthesis-analysis policy unexpectedly configured' >&2
          exit 1
        fi

        if cmake -S "$fixture" -B "$TMPDIR/invalid-timing-oracle-policy" \
          -DCYT_DIR=${coyoteRoot} \
          -DFDEV_NAME:STRING=v80 \
          -DBUILD_APP:STRING=0 \
          -DBUILD_STATIC:STRING=0 \
          -DBUILD_SHELL:STRING=1 \
          -DSTATIC_PATH=${coyoteRoot}/hw/checkpoints \
          -DTIMING_ORACLE_REJECT_RQA_BELOW:STRING=0; then
          echo 'invalid timing-oracle policy unexpectedly configured' >&2
          exit 1
        fi

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

  r5PlatformRenderContract =
    pkgs.runCommand "coyote-v80-r5-platform-render-contract"
      {
        nativeBuildInputs = [
          pkgs.cmake
          pkgs.gnumake
          pkgs.stdenv.cc
          pkgs.tcl
          pkgs.verible
          python
          fakeXilinxTools
        ];
      }
      ''
        set -euo pipefail
        fixture=${coyoteRoot}/tests/coprocessor_ports

        configure_case() {
          name="$1"
          enabled="$2"
          build="$TMPDIR/$name"
          cmake -S "$fixture" -B "$build" \
            -DCYT_DIR=${coyoteRoot} \
            -DFDEV_NAME:STRING=v80 \
            -DBUILD_APP:STRING=0 \
            -DBUILD_STATIC:STRING=1 \
            -DBUILD_SHELL:STRING=0 \
            -DTEST_EN_PR:STRING=0 \
            -DEN_SHELL_PBLOCK:STRING=0 \
            -DTEST_N_COPROCESSOR_PORTS:STRING=0 \
            -DTEST_REGISTER_PROVIDERS:BOOL=OFF \
            -DEN_V80_R5_PLATFORM:STRING="$enabled"
        }

        configure_case disabled 0
        configure_case enabled 1

        cmake -S "$fixture" -B "$TMPDIR/provider-static" \
          -DCYT_DIR=${coyoteRoot} -DFDEV_NAME:STRING=v80 \
          -DBUILD_APP:STRING=0 -DBUILD_STATIC:STRING=1 -DBUILD_SHELL:STRING=0 \
          -DTEST_EN_PR:STRING=0 -DEN_SHELL_PBLOCK:STRING=0 \
          -DTEST_N_COPROCESSOR_PORTS:STRING=1 -DTEST_ENABLE_R5_PROVIDER:BOOL=ON \
          -DEN_V80_R5_PLATFORM:STRING=1
        if cmake -S "$fixture" -B "$TMPDIR/provider-uclk" \
          -DCYT_DIR=${coyoteRoot} -DFDEV_NAME:STRING=v80 \
          -DBUILD_APP:STRING=0 -DBUILD_STATIC:STRING=1 -DBUILD_SHELL:STRING=0 \
          -DTEST_EN_PR:STRING=0 -DEN_SHELL_PBLOCK:STRING=0 -DEN_UCLK:STRING=1 \
          -DTEST_N_COPROCESSOR_PORTS:STRING=1 -DTEST_ENABLE_R5_PROVIDER:BOOL=ON \
          -DEN_V80_R5_PLATFORM:STRING=1; then
          echo 'R5 provider unexpectedly accepted a separate application clock' >&2
          exit 1
        fi
        cmake -S "$fixture" -B "$TMPDIR/provider-shell" \
          -DCYT_DIR=${coyoteRoot} -DFDEV_NAME:STRING=v80 \
          -DBUILD_APP:STRING=0 -DBUILD_STATIC:STRING=0 -DBUILD_SHELL:STRING=1 \
          -DTEST_EN_PR:STRING=1 -DEN_SHELL_PBLOCK:STRING=0 \
          -DSTATIC_PATH:STRING="$TMPDIR/provider-static/checkpoints" \
          -DTEST_N_COPROCESSOR_PORTS:STRING=1 -DTEST_ENABLE_R5_PROVIDER:BOOL=ON \
          -DEN_V80_R5_PLATFORM:STRING=0
        mkdir -p \
          "$TMPDIR/provider-static/coyote-coprocessor-port-fixture_static/hdl/static" \
          "$TMPDIR/provider-shell/coyote-coprocessor-port-fixture_shell/hdl" \
          "$TMPDIR/provider-shell/coyote-coprocessor-port-fixture_shell/xdc"
        (cd "$TMPDIR/provider-static" && ${python}/bin/python write_hdl.py 0 0 0)
        (cd "$TMPDIR/provider-shell" && ${python}/bin/python write_hdl.py 1 0 0)

        ! grep -q 'V80_R5_' "$TMPDIR/disabled/export.cmake"
        ! grep -q 'v80_r5\|platform_dir' "$TMPDIR/disabled/base.tcl"
        test ! -e "$TMPDIR/disabled/export_platform.tcl"
        cmake --build "$TMPDIR/disabled" --target help > "$TMPDIR/disabled-targets"
        if grep -q '^\.\.\. platform$' "$TMPDIR/disabled-targets"; then
          echo 'disabled build unexpectedly exposes the R5 platform target' >&2
          exit 1
        fi

        grep -q 'set(EN_V80_R5_PLATFORM 1)' "$TMPDIR/enabled/export.cmake"
        grep -q 'set(V80_R5_PROCESSOR psv_cortexr5_0)' "$TMPDIR/enabled/export.cmake"
        grep -q 'set(V80_R5_LPD_DATA_BITS 32)' "$TMPDIR/enabled/export.cmake"
        grep -q 'set(V80_R5_LPD_CLOCK_HZ 33333333)' "$TMPDIR/enabled/export.cmake"
        grep -q 'set(V80_R5_SCRATCH_BASE 2147483648)' "$TMPDIR/enabled/export.cmake"
        grep -q 'set(V80_R5_SCRATCH_BYTES 4096)' "$TMPDIR/enabled/export.cmake"
        grep -q 'set(V80_R5_PLATFORM_XSA platform/cyt_top.xsa)' "$TMPDIR/enabled/export.cmake"
        grep -Eq 'set cfg\(en_v80_r5_platform\)[[:space:]]+1' "$TMPDIR/enabled/base.tcl"
        grep -q 'write_hw_platform -fixed -force' "$TMPDIR/enabled/export_platform.tcl"
        grep -q 'V80_R5_PLATFORM_DESIGN_PASS' "$TMPDIR/enabled/check_v80_r5_platform.tcl"
        cmake --build "$TMPDIR/enabled" --target help > "$TMPDIR/enabled-targets"
        grep -q '^\.\.\. platform$' "$TMPDIR/enabled-targets"
        grep -q '^\.\.\. platform-design-check$' "$TMPDIR/enabled-targets"

        tclsh <<'EOF'
        foreach source_file {
          "${coyoteRoot}/hw/bd/versal/cr_pci.tcl"
          "${coyoteRoot}/scripts/ip_inst/common_infrastructure.tcl"
          "${coyoteRoot}/scripts/checks/check_v80_r5_provider_project.tcl.in"
        } {
          set handle [open $source_file r]
          set source [read $handle]
          close $handle
          if {![info complete $source]} {
            puts stderr "$source_file is syntactically incomplete"
            exit 1
          }
        }
        EOF

        grep -q 'CONFIG.PS_PMC_CONFIG_APPLIED {1}' ${coyoteRoot}/hw/bd/versal/cr_pci.tcl
        grep -q 'versal_cips_0/M_AXI_LPD' ${coyoteRoot}/hw/bd/versal/cr_pci.tcl
        grep -q 'r5_scratch_ctrl/S_AXI/Mem0' ${coyoteRoot}/hw/bd/versal/cr_pci.tcl
        grep -q 'versal_cips_0/pl0_resetn' ${coyoteRoot}/hw/bd/versal/cr_pci.tcl

        grep -Eq 'set cfg\(en_v80_r5_provider\)[[:space:]]+1' "$TMPDIR/provider-static/base.tcl"
        grep -q 'r5_provider_clock_converter.*xilinx.com:ip:smartconnect:1.0' \
          ${coyoteRoot}/hw/bd/versal/cr_pci.tcl
        ! grep -q 'xilinx.com:ip:axi_clock_converter' ${coyoteRoot}/hw/bd/versal/cr_pci.tcl
        grep -q 'append xclk_busifs {:r5_provider}' ${coyoteRoot}/hw/bd/versal/cr_pci.tcl
        grep -q 'get_bd_addr_segs r5_provider/Reg' ${coyoteRoot}/hw/bd/versal/cr_pci.tcl
        grep -q 'm_axi_r5_provider' ${coyoteRoot}/hw/templates/versal/static_top_tmplt.txt
        grep -q 's_axi_r5_provider_awaddr' ${coyoteRoot}/hw/templates/common/shell_top_tmplt.txt
        cmake --build "$TMPDIR/provider-static" --target help > "$TMPDIR/provider-static-targets"
        cmake --build "$TMPDIR/provider-shell" --target help > "$TMPDIR/provider-shell-targets"
        grep -q '^\.\.\. provider-project-design-check$' "$TMPDIR/provider-static-targets"
        grep -q '^\.\.\. provider-project-design-check$' "$TMPDIR/provider-shell-targets"
        grep -q 'V80_R5_PROVIDER_PROJECT_PASS' \
          "$TMPDIR/provider-static/check_v80_r5_provider_project.tcl"
        grep -q 'r5_coprocessor_provider_stack inst_r5_provider' \
          "$TMPDIR/provider-shell/coyote-coprocessor-port-fixture_shell/hdl/dynamic_top.sv"
        grep -q 'r5_provider_axil_ccross inst_r5_provider_ccross' \
          "$TMPDIR/provider-shell/coyote-coprocessor-port-fixture_shell/hdl/shell_top.sv"
        grep -q 'addr_width <= 32 ? "4G" : "16E"' \
          ${coyoteRoot}/scripts/ip_inst/common_infrastructure.tcl
        grep -q 'create_bd_port -dir I -type clk -freq_hz' \
          ${coyoteRoot}/scripts/ip_inst/common_infrastructure.tcl
        grep -q 'axil_clock_converter 64 64 $cfg(aclk_f) $cfg(uclk_f)' \
          ${coyoteRoot}/scripts/ip_inst/common_infrastructure.tcl
        grep -q 'axil_clock_converter_32 32 32 $cfg(sclk_f) $cfg(aclk_f)' \
          ${coyoteRoot}/scripts/ip_inst/common_infrastructure.tcl
        grep -q 's_axi_coprocessor_ctrl(axi_coprocessor_ctrl)' \
          "$TMPDIR/provider-shell/coyote-coprocessor-port-fixture_shell/hdl/shell_top.sv"
        verible-verilog-syntax \
          "$TMPDIR/provider-static/coyote-coprocessor-port-fixture_static/hdl/static/static_top.sv" \
          "$TMPDIR/provider-static/coyote-coprocessor-port-fixture_static/hdl/static/cyt_top.sv" \
          "$TMPDIR/provider-static/coyote-coprocessor-port-fixture_static/hdl/static/shell_top.sv" \
          "$TMPDIR/provider-shell/coyote-coprocessor-port-fixture_shell/hdl/dynamic_top.sv" \
          "$TMPDIR/provider-shell/coyote-coprocessor-port-fixture_shell/hdl/shell_top.sv"

        for invalid in u280 shell pr bad-boolean; do
          args=(
            -DCYT_DIR=${coyoteRoot}
            -DFDEV_NAME:STRING=v80
            -DBUILD_APP:STRING=0
            -DBUILD_STATIC:STRING=1
            -DBUILD_SHELL:STRING=0
            -DTEST_EN_PR:STRING=0
            -DEN_SHELL_PBLOCK:STRING=0
            -DTEST_N_COPROCESSOR_PORTS:STRING=0
            -DTEST_REGISTER_PROVIDERS:BOOL=OFF
            -DEN_V80_R5_PLATFORM:STRING=1
          )
          case "$invalid" in
            u280) args+=( -DFDEV_NAME:STRING=u280 ) ;;
            shell) args+=( -DBUILD_STATIC:STRING=0 -DBUILD_SHELL:STRING=1 ) ;;
            pr) args+=( -DTEST_EN_PR:STRING=1 ) ;;
            bad-boolean) args+=( -DEN_V80_R5_PLATFORM:STRING=yes ) ;;
          esac
          if cmake -S "$fixture" -B "$TMPDIR/reject-$invalid" "''${args[@]}"; then
            echo "invalid R5 platform case unexpectedly configured: $invalid" >&2
            exit 1
          fi
        done

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

  r5ProviderSimulation =
    pkgs.runCommand "coyote-r5-provider-simulation"
      {
        nativeBuildInputs = [
          pkgs.stdenv.cc
          pkgs.python3
          pkgs.verilator
        ];
      }
      ''
        set -euo pipefail
        verilator --binary --timing --assert --top-module r5_packet_queue_provider_tb \
          -Wall -Wno-fatal \
          ${coyoteRoot}/hw/hdl/coprocessor/r5_packet_queue_provider.sv \
          ${coyoteRoot}/hw/tests/r5_packet_queue_provider_tb.sv
        ./obj_dir/Vr5_packet_queue_provider_tb
        touch "$out"
      '';

  r5ProviderStackLint =
    pkgs.runCommand "coyote-r5-provider-stack-lint"
      {
        nativeBuildInputs = [ pkgs.verilator ];
      }
      ''
        set -euo pipefail
        verilator --lint-only --top-module r5_coprocessor_provider_stack \
          -Wall -Wno-fatal \
          ${coyoteRoot}/hw/hdl/coprocessor/coprocessor_port_gateway.sv \
          ${coyoteRoot}/hw/hdl/coprocessor/coprocessor_control_target.sv \
          ${coyoteRoot}/hw/hdl/coprocessor/r5_packet_queue_provider.sv \
          ${coyoteRoot}/hw/hdl/coprocessor/r5_coprocessor_provider_stack.sv
        touch "$out"
      '';

  r5ProviderModel =
    pkgs.runCommand "coyote-r5-provider-model"
      {
        nativeBuildInputs = [ pkgs.stdenv.cc ];
      }
      ''
        set -euo pipefail
        c++ -std=c++20 -O2 -Wall -Wextra -Werror \
          ${coyoteRoot}/tests/coprocessor_ports/r5_provider_model_test.cpp \
          -o r5-provider-model-test
        ./r5-provider-model-test
        touch "$out"
      '';

  mkCoprocessorApplicationRender =
    {
      appSource,
      pname ? "coyote-coprocessor-application-render",
    }:
    pkgs.runCommand pname
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
        shell_build="$TMPDIR/provider-shell"
        cmake -S "$fixture" -B "$shell_build" \
          -DCYT_DIR=${coyoteRoot} -DFDEV_NAME:STRING=v80 \
          -DBUILD_APP:STRING=0 -DBUILD_STATIC:STRING=0 -DBUILD_SHELL:STRING=1 \
          -DTEST_EN_PR:STRING=1 -DEN_SHELL_PBLOCK:STRING=0 \
          -DSTATIC_PATH:STRING=${coyoteRoot}/hw/checkpoints \
          -DTEST_N_COPROCESSOR_PORTS:STRING=1 -DTEST_ENABLE_R5_PROVIDER:BOOL=ON
        mkdir -p \
          "$shell_build/coyote-coprocessor-port-fixture_shell/hdl" \
          "$shell_build/coyote-coprocessor-port-fixture_shell/xdc"
        (cd "$shell_build" && ${python}/bin/python write_hdl.py 1 0 0)

        app_build="$TMPDIR/provider-app"
        cmake -S ${appSource} -B "$app_build" \
          -DCYT_DIR=${coyoteRoot} -DFDEV_NAME:STRING=v80 \
          -DBUILD_APP:STRING=1 -DBUILD_STATIC:STRING=0 -DBUILD_SHELL:STRING=0 \
          -DSHELL_PATH:STRING="$shell_build"
        wrapper_root="$app_build/coyote-coprocessor-application-fixture_config_0/user_c0_0/hdl"
        mkdir -p "$wrapper_root/wrappers" \
          "$app_build/coyote-coprocessor-application-fixture_config_0/user_c0_0/xdc"
        (cd "$app_build" && ${python}/bin/python write_hdl.py 2 0 0)

        grep -q '`include "vfpga_top.svh"' "$wrapper_root/wrappers/user_logic_c0_0.sv"
        grep -q 'inst_coprocessor_fixture' ${appSource}/src/vfpga_top.svh
        test -f ${appSource}/src/hdl/coprocessor_application_fixture.sv
        grep -q 'coprocessor_0_recv_tdata' "$wrapper_root/wrappers/user_wrapper_c0_0.sv"
        {
          echo 'module vfpga_top_syntax_fixture;'
          cat ${appSource}/src/vfpga_top.svh
          echo 'endmodule'
        } > "$TMPDIR/vfpga_top_syntax_fixture.sv"
        verible-verilog-syntax \
          ${appSource}/src/hdl/coprocessor_application_fixture.sv \
          "$TMPDIR/vfpga_top_syntax_fixture.sv" \
          "$wrapper_root/wrappers/user_logic_c0_0.sv" \
          "$wrapper_root/wrappers/user_wrapper_c0_0.sv"
        touch "$out"
      '';

  physicalTclGeneration =
    pkgs.runCommand "coyote-u280-generated-physical-tcl-contract"
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
        if grep -R --include='*.in' -E '\$\{[a-z_]' ${coyoteRoot}/scripts >/dev/null; then
          echo 'configured Coyote template contains Tcl runtime syntax consumed by configure_file' >&2
          exit 1
        fi
        fixture=${coyoteRoot}/tests/resident_service_control
        build="$TMPDIR/generated-u280-place"
        cmake -S "$fixture" -B "$build" \
          -DCYT_DIR=${coyoteRoot} \
          -DFDEV_NAME:STRING=u280 \
          -DBUILD_APP:STRING=0 \
          -DBUILD_STATIC:STRING=0 \
          -DBUILD_SHELL:STRING=1 \
          -DSTATIC_PATH=${coyoteRoot}/hw/checkpoints \
          -DIMMUTABLE_IMPLEMENTATION_STAGES:BOOL=ON \
          -DIMPLEMENTATION_PHASE:STRING=place \
          -DIMPLEMENTATION_INPUT_DCP:FILEPATH="$build/checkpoints/input.dcp" \
          -DIMPLEMENTATION_OUTPUT_DCP:FILEPATH="$build/checkpoints/output.dcp" \
          -DIMPLEMENTATION_COMPLETION_PATH:FILEPATH="$build/checkpoints/place_complete" \
          -DIMPLEMENTATION_REPORT_DIR:PATH="$build/reports" \
          -DIMPLEMENTATION_TELEMETRY_PATH:FILEPATH="$build/reports/physical.json" \
          -DIMPLEMENTATION_OPT_DIRECTIVE:STRING=Explore

        test -f "$build/base.tcl"
        test -f "$build/physical_stage.tcl"
        chmod u+w "$build/base.tcl" "$build/physical_stage.tcl"
        ${python}/bin/python \
          ${../nix/tools/patch-u280-vivado-2023.2-physical-stage.py} \
          "$build/base.tcl" "$build/physical_stage.tcl"

        grep -F 'set prefix [format "shell_%s" $phase]' "$build/base.tcl" >/dev/null
        grep -F '[format "%s_timing_summary%s.rpt" $prefix $report_suffix]' \
          "$build/base.tcl" >/dev/null
        if grep -E '\$\{[a-z_]' "$build/base.tcl" "$build/physical_stage.tcl" >/dev/null; then
          echo 'generated physical Tcl contains runtime syntax consumed by configure_file' >&2
          exit 1
        fi

        awk '
          /^        place \{/ { copying = 1 }
          /^        route \{/ { copying = 0 }
          copying { print }
        ' "$build/physical_stage.tcl" > "$build/place-case.tcl"
        grep -F 'opt_design -directive $directive' "$build/place-case.tcl" >/dev/null
        grep -F 'place_design -directive $place_directive' "$build/place-case.tcl" >/dev/null
        grep -F 'if {$cfg(peer_backend) eq "aurora_qsfp1"} {' \
          "$build/physical_stage.tcl" >/dev/null
        grep -F 'gt1_rxp_in[0] G53' "$build/physical_stage.tcl" >/dev/null
        grep -F 'reset_property PACKAGE_PIN $selected_port' "$build/physical_stage.tcl" >/dev/null
        grep -F 'gen_channel_container\[24\]' "$build/physical_stage.tcl" >/dev/null
        grep -F 'Expected exactly one Aurora channel' "$build/physical_stage.tcl" >/dev/null
        grep -F '3 GTYE4_CHANNEL_X0Y44 2 GTYE4_CHANNEL_X0Y45' \
          "$build/physical_stage.tcl" >/dev/null
        opt_line="$(grep -n 'opt_design' "$build/place-case.tcl" | head -1 | cut -d: -f1)"
        place_line="$(grep -n 'place_design' "$build/place-case.tcl" | head -1 | cut -d: -f1)"
        test "$opt_line" -lt "$place_line"

        checkpoint_line="$(grep -n 'write_checkpoint -force' "$build/physical_stage.tcl" | cut -d: -f1)"
        observation_line="$(grep -n 'write_implementation_observations' \
          "$build/physical_stage.tcl" | tail -1 | cut -d: -f1)"
        test "$checkpoint_line" -lt "$observation_line"

        v80_build="$TMPDIR/generated-v80-route"
        cmake -S "$fixture" -B "$v80_build" \
          -DCYT_DIR=${coyoteRoot} \
          -DFDEV_NAME:STRING=v80 \
          -DBUILD_APP:STRING=0 \
          -DBUILD_STATIC:STRING=0 \
          -DBUILD_SHELL:STRING=1 \
          -DSTATIC_PATH=${coyoteRoot}/hw/checkpoints \
          -DIMMUTABLE_IMPLEMENTATION_STAGES:BOOL=ON \
          -DIMPLEMENTATION_PHASE:STRING=route \
          -DIMPLEMENTATION_INPUT_DCP:FILEPATH="$v80_build/checkpoints/input.dcp" \
          -DIMPLEMENTATION_OUTPUT_DCP:FILEPATH="$v80_build/checkpoints/output.dcp" \
          -DIMPLEMENTATION_COMPLETION_PATH:FILEPATH="$v80_build/checkpoints/route_complete" \
          -DIMPLEMENTATION_REPORT_DIR:PATH="$v80_build/reports" \
          -DIMPLEMENTATION_TELEMETRY_PATH:FILEPATH="$v80_build/reports/physical.json"
        grep -F 'set phase "route"' "$v80_build/physical_stage.tcl" >/dev/null
        grep -F 'set prefix [format "shell_%s" $phase]' "$v80_build/base.tcl" >/dev/null
        grep -F '[format "%s_utilization%s.rpt" $prefix $report_suffix]' \
          "$v80_build/base.tcl" >/dev/null
        grep -F '[format "%s_route_status%s.rpt" $prefix $report_suffix]' \
          "$v80_build/base.tcl" >/dev/null
        grep -F '[format "shell_%s_incremental_reuse%s.rpt" $phase $report_suffix]' \
          "$v80_build/physical_stage.tcl" >/dev/null
        if grep -E '\$\{[a-z_]' "$v80_build/base.tcl" "$v80_build/physical_stage.tcl" >/dev/null; then
          echo 'generated V80 physical Tcl contains runtime syntax consumed by configure_file' >&2
          exit 1
        fi

        for board_phase in u280:route u280:validate v80:validate; do
          board="''${board_phase%%:*}"
          phase="''${board_phase#*:}"
          phase_build="$TMPDIR/generated-$board-$phase"
          cmake -S "$fixture" -B "$phase_build" \
            -DCYT_DIR=${coyoteRoot} \
            -DFDEV_NAME:STRING="$board" \
            -DBUILD_APP:STRING=0 \
            -DBUILD_STATIC:STRING=0 \
            -DBUILD_SHELL:STRING=1 \
            -DSTATIC_PATH=${coyoteRoot}/hw/checkpoints \
            -DIMMUTABLE_IMPLEMENTATION_STAGES:BOOL=ON \
            -DIMPLEMENTATION_PHASE:STRING="$phase" \
            -DIMPLEMENTATION_INPUT_DCP:FILEPATH="$phase_build/checkpoints/input.dcp" \
            -DIMPLEMENTATION_OUTPUT_DCP:FILEPATH="$phase_build/checkpoints/output.dcp" \
            -DIMPLEMENTATION_COMPLETION_PATH:FILEPATH="$phase_build/checkpoints/complete" \
            -DIMPLEMENTATION_REPORT_DIR:PATH="$phase_build/reports" \
            -DIMPLEMENTATION_REPORT_SUFFIX:STRING=_c0 \
            -DIMPLEMENTATION_TELEMETRY_PATH:FILEPATH="$phase_build/reports/physical.json" \
            -DIMPLEMENTATION_VALIDATION_SUMMARY:FILEPATH="$phase_build/reports/validation.json"
          grep -F "set phase \"$phase\"" "$phase_build/physical_stage.tcl" >/dev/null
          grep -F '[format "%s_utilization%s.rpt" $prefix $report_suffix]' \
            "$phase_build/base.tcl" >/dev/null
          grep -F '[format "%s_route_status%s.rpt" $prefix $report_suffix]' \
            "$phase_build/base.tcl" >/dev/null
          grep -F '[format "shell_drc_bitstream_checks%s.rpt" $report_suffix]' \
            "$phase_build/physical_stage.tcl" >/dev/null
          if grep -E '\$\{[a-z_]' "$phase_build/base.tcl" "$phase_build/physical_stage.tcl" >/dev/null; then
            echo "generated $board $phase Tcl contains runtime syntax consumed by configure_file" >&2
            exit 1
          fi
        done
        touch "$out"
      '';

  auroraWidthAdapterSimulation =
    pkgs.runCommand "coyote-aurora-width-adapter-simulation"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.stdenv.cc
          pkgs.verilator
        ];
      }
      ''
        set -euo pipefail
        verilator --binary --timing -Wall -Wno-fatal \
          --top-module aurora_width_adapter_tb \
          ${coyoteRoot}/hw/hdl/aurora/aurora_width_adapter.sv \
          ${coyoteRoot}/hw/tests/aurora_width_adapter_tb.sv
        ./obj_dir/Vaurora_width_adapter_tb
        touch "$out"
      '';

  auroraRegisteredReadySimulation =
    pkgs.runCommand "coyote-aurora-registered-ready-simulation"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.stdenv.cc
          pkgs.verilator
        ];
      }
      ''
        set -euo pipefail
        buffer=${coyoteRoot}/hw/hdl/aurora/aurora_axis_skid_buffer.sv
        adapter=${coyoteRoot}/hw/hdl/aurora/aurora_width_adapter.sv
        wrapper=${coyoteRoot}/hw/hdl/aurora/aurora_module.sv
        grep -Fq 'logic         completed_valid;' "$adapter"
        grep -Fq 'assign m_tvalid = completed_valid;' "$adapter"
        grep -Fq 'assign overflow = completion && !completion_ready;' "$adapter"
        if grep -Eq '(low_data|low_keep|completed_data|completed_keep)[[:space:]]*<=[[:space:]]*'"'"'0' "$adapter"; then
          echo "invalid Aurora width-adapter payload must not be reset" >&2
          exit 1
        fi
        grep -Fq "queue_count != 2'd2" "$buffer"
        if grep -Eq 's_tready[[:space:]]*=.*m_tready' "$buffer"; then
          echo "Aurora RX ready must not depend on downstream ready" >&2
          exit 1
        fi
        if grep -Eq 'queue_(data|keep|last).*<=[[:space:]]*'"'"'0' "$buffer"; then
          echo "invalid Aurora skid-buffer payload must not be reset" >&2
          exit 1
        fi
        grep -Fq '.m_axis_tready  (rx_cdc_ready)' "$wrapper"
        grep -Fq 'aurora_axis_skid_buffer inst_rx_output_buffer' "$wrapper"
        grep -Fq ') inst_tx_output_buffer (' "$wrapper"
        grep -Fq '.m_tready  (tx_adapter_ready)' "$wrapper"
        grep -Fq '.m_tready  (tx_tready)' "$wrapper"
        if grep -A20 -F 'aurora_tx_512_to_256 inst_tx_width_adapter' "$wrapper" |
          grep -Fq '.m_tready  (tx_tready)'; then
          echo "Aurora TX width adapter regressed across the registered core boundary" >&2
          exit 1
        fi
        verilator --binary --timing -Wall -Wno-fatal \
          --top-module aurora_axis_skid_buffer_tb \
          "$buffer" \
          ${coyoteRoot}/hw/tests/aurora_axis_skid_buffer_tb.sv
        ./obj_dir/Vaurora_axis_skid_buffer_tb
        touch "$out"
      '';

  auroraModuleElaboration =
    pkgs.runCommand "coyote-aurora-module-elaboration"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.stdenv.cc
          pkgs.verilator
        ];
      }
      ''
        set -euo pipefail
        verilator --binary --timing -Wall -Wno-fatal \
          --top-module aurora_module_elaboration_tb \
          ${coyoteRoot}/hw/tests/aurora_module_elaboration_tb.sv \
          ${coyoteRoot}/hw/hdl/aurora/aurora_width_adapter.sv \
          ${coyoteRoot}/hw/hdl/aurora/aurora_axis_skid_buffer.sv \
          ${coyoteRoot}/hw/hdl/aurora/aurora_module.sv
        ./obj_dir/Vaurora_module_elaboration_tb
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
    auroraModuleElaboration
    auroraRegisteredReadySimulation
    auroraWidthAdapterSimulation
    coprocessorHostApi
    coprocessorRenderContract
    coprocessorSimulation
    hostApiCompile
    mkCoprocessorApplicationRender
    physicalTclGeneration
    r5PlatformRenderContract
    r5ProviderModel
    r5ProviderSimulation
    r5ProviderStackLint
    renderContract
    routeValidationContract
    splitterSimulation
    ;
}
