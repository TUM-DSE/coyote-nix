# Evaluate shells, applications and every example against a fixture site
# without building hardware. Build the generated shell sources and the CPU
# host programs, which need no vendor tools.
{
  pkgs,
  coyoteNixLib,
}:
let
  inherit (pkgs) lib;

  # The smallest site coyote-nix accepts. Boards without a coyote-nix
  # profile must be ignored.
  site = {
    xilinxShareRoot = "/nonexistent/xilinx";
    boards = {
      u280.xilinxVersion = "fixture-u280-version";
      v80.xilinxVersion = "fixture-v80-version";
      agilex7.quartusVersion = "fixture-quartus-version";
    };
  };
  examples = coyoteNixLib.mkCoyoteExamples { inherit pkgs site; };

  mkShell = args: coyoteNixLib.mkCoyoteShell ({ inherit pkgs site; } // args);
  fails = value: !(builtins.tryEval (builtins.deepSeq value value)).success;
  failsDrv = drv: !(builtins.tryEval drv.drvPath).success;

  names = board: lib.attrNames examples.${board};
  expected = {
    u280 = [
      "gpu_p2p"
      "hello_world"
      "hls_vadd"
      "multitenancy"
      "multithreading"
      "packet_sniffer"
      "perf_fpga"
      "perf_rdma"
      "reconfigure_shell"
      "shells"
      "spinal_hdl"
      "user_interrupts"
    ];
    v80 = [
      "app_reconfiguration"
      "gpu_p2p"
      "hello_world"
      "hls_vadd"
      "multitenancy"
      "multithreading"
      "perf_fpga"
      "reconfigure_shell"
      "shells"
      "spinal_hdl"
      "user_interrupts"
    ];
    u280Shells = [
      "mem1-rdma-sniffer-opt"
      "strm1"
      "strm1-mem1-opt"
      "strm2"
      "strm2-rdma-opt"
      "strm4"
    ];
    v80Shells = [
      "strm1"
      "strm1-mem1-opt"
      "strm2"
      "strm4"
    ];
  };

  drvPathOf = drv: builtins.unsafeDiscardOutputDependency drv.drvPath;
  # Evaluates every example, shell, application and stage.
  allDrvPaths = lib.concatMap (
    board:
    lib.concatMap (
      example:
      [ (drvPathOf example) ]
      ++ map drvPathOf (
        lib.filter lib.isDerivation [
          (example.sw or null)
          (example.app or null)
          (example.hw or null)
        ]
      )
      ++ map drvPathOf (lib.attrValues (example.stages or { }))
    ) (lib.attrValues (removeAttrs examples.${board} [ "shells" ]))
    ++ map drvPathOf (lib.attrValues examples.${board}.shells)
  ) (lib.attrNames examples);

  rejectedSite =
    badSite:
    fails (
      coyoteNixLib.mkCoyoteExamples {
        inherit pkgs;
        site = badSite;
      }
    );
  rejectedSiteBoard =
    badSite:
    fails
      (coyoteNixLib.mkCoyoteExamples {
        inherit pkgs;
        site = badSite;
      }).u280;

  u280 = examples.u280;
  v80 = examples.v80;
  # The CPU host programs; the GPU example needs ROCm, which is large.
  cpuSoftware = lib.filter (example: example ? sw && example.sw.meta.mainProgram != "gpu_p2p") (
    lib.attrValues (removeAttrs u280 [ "shells" ])
  );
  sniffer = u280.packet_sniffer.shell;
in
assert names "u280" == expected.u280;
assert names "v80" == expected.v80;
assert lib.attrNames u280.shells == expected.u280Shells;
assert lib.attrNames v80.shells == expected.v80Shells;
assert !(examples ? agilex7);
# Software is shared across boards, shells across examples.
assert u280.hello_world.sw == v80.hello_world.sw;
assert u280.hls_vadd.shell == u280.spinal_hdl.shell;
assert u280.user_interrupts.shell == u280.perf_fpga.shell;
assert u280.hello_world.app.shell == u280.hello_world.shell;
assert u280.hello_world.shell.coyoteShell.services.cardMemory == 1;
# Requesting the same shell directly gives the same derivation.
assert
  mkShell {
    board = "u280";
    services.hostStreams = 2;
  } == u280.hls_vadd.shell;
assert !(u280.reconfigure_shell ? app);
assert u280.multitenancy ? hw && !(u280.multitenancy ? shell);
assert v80.app_reconfiguration ? hw && !(v80.app_reconfiguration ? shell);
# Site validation.
assert rejectedSite { boards = { }; };
assert rejectedSiteBoard {
  xilinxShareRoot = "/x";
  boards.u280 = { };
};
# Service and shell validation.
assert fails (mkShell {
  board = "u280";
  services.unknown = 1;
});
assert fails (mkShell {
  board = "u280";
  services.vfpgas = 16;
});
assert fails (mkShell {
  board = "v80";
  services.rdma = true;
});
# Shells are staged with one vFPGA and one configuration.
assert fails
  (mkShell {
    board = "u280";
    services.vfpgas = 2;
  }).coyoteShell.services;
assert fails
  (mkShell {
    board = "v80";
    services.configurations = 2;
  }).coyoteShell.services;
assert failsDrv (mkShell {
  board = "u280";
  cmakeFlags = [ "-DEN_MEM=1" ];
});
assert failsDrv (mkShell {
  board = "v80";
  static = "source";
});
# Non-default choices show up in the name as a hash suffix.
assert
  builtins.match "strm1-[0-9a-f]{8}"
    (mkShell {
      board = "u280";
      static = "source";
    }).coyoteShell.name != null;
pkgs.runCommand "coyote-nix-examples"
  {
    drvPaths = lib.concatStringsSep "\n" allDrvPaths;
    passAsFile = [ "drvPaths" ];
  }
  ''
    test "$(wc -l < "$drvPathsPath")" -gt 40
    ${lib.concatMapStrings (example: ''
      test -x ${example.sw}/bin/${example.sw.meta.mainProgram}
      test -f ${example.sw}/lib/libcoyote.so
    '') cpuSoftware}

    # Generated shell project: the placeholder, with ports matching the
    # services.
    grep -q 'VFPGA_C0_0 "placeholder/region_0"' ${sniffer.hwSource}/CMakeLists.txt
    placeholder=${sniffer.hwSource}/placeholder/region_0/vfpga_top.svh
    grep -q 'gen_card_loopback' "$placeholder"
    grep -q 'gen_rdma_tie_off' "$placeholder"
    grep -q 'filter_config.tie_off_m' "$placeholder"
    grep -q 'rq_wr.tie_off_s' "$placeholder"
    ! grep -q 'gen_host_loopback' "$placeholder"

    touch "$out"
  ''
