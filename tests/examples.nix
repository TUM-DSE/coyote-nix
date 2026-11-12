# Evaluate every example against a fixture site without building hardware,
# and build the host programs, which need no vendor tools.
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

  names = board: lib.concatStringsSep " " (lib.attrNames examples.${board});
  expected = {
    u280 = lib.concatStringsSep " " [
      "gpu_p2p"
      "hello_world"
      "hls_vadd"
      "multitenancy"
      "multithreading"
      "packet_sniffer"
      "perf_fpga"
      "perf_rdma"
      "reconfigure_shell"
      "spinal_hdl"
      "user_interrupts"
    ];
    v80 = lib.concatStringsSep " " [
      "app_reconfiguration"
      "gpu_p2p"
      "hello_world"
      "hls_vadd"
      "multitenancy"
      "multithreading"
      "perf_fpga"
      "reconfigure_shell"
      "spinal_hdl"
      "user_interrupts"
    ];
  };

  drvPathOf = drv: builtins.unsafeDiscardOutputDependency drv.drvPath;
  # Evaluates every example and every hardware stage.
  allDrvPaths = lib.concatMap (
    board:
    lib.concatMap (
      example:
      [
        (drvPathOf example)
        (drvPathOf example.sw)
      ]
      ++ map drvPathOf (lib.attrValues (example.stages or { }))
    ) (lib.attrValues examples.${board})
  ) (lib.attrNames examples);

  examplesFor = badSite: coyoteNixLib.mkCoyoteExamples {
    inherit pkgs;
    site = badSite;
  };
  rejected = badSite: !(builtins.tryEval (examplesFor badSite)).success;
  rejectedBoard = badSite: !(builtins.tryEval (examplesFor badSite).u280).success;

  # The GPU example needs ROCm, which is large; the eval check covers it.
  cpuSoftware = lib.filterAttrs (name: _: name != "gpu_p2p") examples.u280;
  v80Patched = examples.v80.app_reconfiguration.stages.synth;
in
assert names "u280" == expected.u280;
assert names "v80" == expected.v80;
assert !(examples ? agilex7);
assert examples.u280.hello_world.sw == examples.v80.hello_world.sw;
assert !(examples.u280.reconfigure_shell ? hw);
assert rejected { boards = { }; };
assert rejectedBoard {
  xilinxShareRoot = "/x";
  boards.u280 = { };
};
assert lib.hasSuffix "/examples/10_app_reconfiguration/hw" (toString v80Patched.src);
pkgs.runCommand "coyote-nix-examples"
  {
    drvPaths = lib.concatStringsSep "\n" allDrvPaths;
    passAsFile = [ "drvPaths" ];
  }
  ''
    test "$(wc -l < "$drvPathsPath")" -gt 40
    ${lib.concatMapStrings (sw: ''
      test -x ${sw.sw}/bin/${sw.sw.meta.mainProgram}
      test -f ${sw.sw}/lib/libcoyote.so
    '') (lib.attrValues cpuSoftware)}
    # The V80 variant of the reconfiguration example selects the V80 floorplan.
    grep -qx 'set(FDEV_NAME "v80")' ${v80Patched.src}/CMakeLists.txt
    test -f ${v80Patched.src}/../../../cmake/FindCoyoteHW.cmake
    touch "$out"
  ''
