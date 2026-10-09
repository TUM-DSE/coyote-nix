{ pkgs, coyoteLib }:
let
  args = {
    inherit pkgs;
    tools = coyoteLib.mkTools {
      inherit pkgs;
      coyoteRoot = ../.;
      xilinxShareRoot = "/nonexistent/xilinx";
    };
    coyoteRoot = ../.;
    hwSource = ../.;
    xilinxShareRoot = "/nonexistent/xilinx";
    board = "v80";
    xilinxVersion = "2025.1";
    pname = "region-topology";
  };
  topology = regions: {
    configurations = 1;
    inherit regions;
  };
  shell =
    regions: coyoteLib.mkCoyoteShellPackage (args // { implementation.topology = topology regions; });
  accepts = value: (builtins.tryEval value.drvPath).success;
  one = shell 1;
  three = shell 3;
  appFor =
    shellPackage:
    coyoteLib.mkCoyoteAppPackage {
      inherit pkgs shellPackage;
      tools = args.tools;
      coyoteRoot = ../.;
      hwSource = ../.;
      xilinxShareRoot = "/nonexistent/xilinx";
      pname = "region-app";
    };
  stagingCases = pkgs.writeText "region-staging-cases.json" (
    builtins.toJSON (
      map
        (count: {
          inherit count;
          phases = map (name: {
            inherit name;
            buildPhase =
              builtins.unsafeDiscardStringContext
                (shell count).coyoteTwoStage.stages.${name}.buildPhase;
          }) [ "link" ];
        })
        [
          1
          3
        ]
    )
  );
in
assert accepts one;
assert accepts three;
assert accepts (shell 15);
assert !accepts (shell 0);
assert !accepts (shell 16);
assert !accepts (shell ("3"));
assert accepts (appFor one);
assert !accepts (appFor three);
assert
  !accepts (
    coyoteLib.mkCoyoteShellPackage (
      args
      // {
        board = "u280";
        implementation.topology = topology 3;
      }
    )
  );
assert
  !accepts (
    coyoteLib.mkCoyoteShellPackage (
      args
      // {
        implementation.topology = topology 3;
        cmakeFlags = [ "-DN_REGIONS:STRING=1" ];
      }
    )
  );
assert one.coyoteTwoStage.topology == topology 1;
assert three.coyoteTwoStage.topology == topology 3;
assert
  (map (entry: entry.cell) three.coyoteTwoStage.physicalRegions) == [
    "inst_shell/inst_dynamic/inst_user_wrapper_0"
    "inst_shell/inst_dynamic/inst_user_wrapper_1"
    "inst_shell/inst_dynamic/inst_user_wrapper_2"
  ];
assert
  (map (entry: entry.seedCheckpoint) three.coyoteTwoStage.physicalRegions) == [
    "checkpoints/config_0/user_synthed_c0_0.dcp"
    "checkpoints/config_0/user_synthed_c0_1.dcp"
    "checkpoints/config_0/user_synthed_c0_2.dcp"
  ];
assert
  three.coyoteTwoStage.expectedBitstreams == [
    "cyt_top.pdi"
    "config_0/vfpga_c0_0.pdi"
    "config_0/vfpga_c0_1.pdi"
    "config_0/vfpga_c0_2.pdi"
  ];
pkgs.runCommand "region-topology-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.cmake
      pkgs.gnumake
    ];
  }
  ''
    python3 ${./region-staging.py} ${stagingCases} ${../nix/tools/coyote-implementation-stage.py}
    python3 ${./region-shell-contract.py} ${../nix/tools/coyote-region-contract.py}
    touch "$out"
  ''
