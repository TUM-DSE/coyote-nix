# coyote-nix

Reusable Nix tooling for Coyote FPGA development.

This repository is intended to hold the generic Coyote/Xilinx/Nix support that can be shared by Coyote-based projects. Project repositories should keep their own source layout, package names, build DAGs, Xilinx installation path, and artifact policy, and call the functions exposed here.

`coyote-nix` does not provide preconfigured Vivado/Vitis packages by itself. A consuming project must provide a Xilinx installation path via `xilinxShareRoot` when constructing tools or hardware builds.

## What belongs here

- Xilinx tool wrappers (`vivado`, `hw_server`, `vitis_hls`)
- common Coyote shell tools (`program-cli`, `deploy-hw`, driver lifecycle helpers, hot reset, hugepages)
- generic Coyote hardware stage derivation builder
- generic Coyote kernel driver derivation builder
- reusable dev shell construction

## What should stay in consuming projects

- project-specific host packages
- project artifact package names such as `my-u280-bitstream`
- synthesis/routing/bitgen stage graph
- project-specific CMake flags
- expected artifact lists
- simulation project names and `xdb` defaults

## Library functions

The flake exposes:

```nix
coyote-nix.lib.mkTools
coyote-nix.lib.mkCoyoteHwStagePackage
coyote-nix.lib.mkCoyoteDriverPackage
coyote-nix.lib.mkCoyoteDevShell
coyote-nix.lib.mkApp
```

Example shape for a consuming flake:

```nix
let
  xilinxShareRoot = /path/to/xilinx;
  coyoteTools = coyote-nix.lib.mkTools {
    inherit pkgs xilinxShareRoot;
    coyoteRoot = coyote;
  };
in {
  packages.my-board = coyote-nix.lib.mkCoyoteHwStagePackage {
    inherit pkgs;
    tools = coyoteTools;
    coyoteRoot = coyote;
    inherit xilinxShareRoot;
    hwSource = ./hw;
    pname = "my-board";
    platform = "u280";
    coyotePlatform = "ultrascale";
    xilinxVersion = "2023.2";
    buildCommands = [ "make project" "make bitgen" ];
    expectedPaths = [ "bitstreams/cyt_top.bit" ];
  };
}
```

Deployment helpers do not bake in project package names. A consuming project can set defaults through environment variables such as:

```sh
export COYOTE_NIX_ULTRASCALE_FPGA_PACKAGE=my-u280-package
export COYOTE_NIX_VERSAL_FPGA_PACKAGE=my-v80-package
export COYOTE_NIX_ULTRASCALE_FPGA_ARTIFACT=cyt_top.bit
export COYOTE_NIX_VERSAL_FPGA_ARTIFACT=cyt_top.pdi
```

or pass explicit image paths to commands like `program-cli` and `deploy-hw`.
