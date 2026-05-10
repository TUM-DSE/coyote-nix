# coyote-nix

Reusable Nix tooling for Coyote FPGA development.

This repository provides generic Coyote/Xilinx/Nix mechanics that can be shared by Coyote-based projects. It does not encode a deployment site's Xilinx installation path or vendor tool version policy; consuming projects must pass those values in from their site configuration.

`coyote-nix` does not provide preconfigured Vivado/Vitis packages by itself. A consuming project must provide a Xilinx installation path via `xilinxShareRoot` when constructing tools or hardware builds.

## Scope

Provided here:

- Xilinx tool wrappers (`vivado`, `hw_server`, `vitis_hls`)
- common Coyote shell tools (`program-cli`, `deploy-hw`, driver lifecycle helpers, hot reset, hugepages)
- generic Coyote hardware stage derivation builder
- generic U280/V80 Coyote board-flow builders
- generic Coyote kernel driver derivation and matrix builders
- reusable dev shell construction

Kept in consuming projects or site flakes:

- Xilinx installation path and available/preferred tool versions
- project source layout
- project package names
- project-specific CMake overrides
- project-specific simulation names and `xdb` defaults
- host/cluster inventory and driver-kernel policy

## Library functions

The flake exposes:

```nix
coyote-nix.lib.mkTools
coyote-nix.lib.mkCoyoteHwStagePackage
coyote-nix.lib.mkCoyoteBoardPackages
coyote-nix.lib.mkCoyoteDriverPackage
coyote-nix.lib.mkCoyoteDriverPackages
coyote-nix.lib.mkCoyoteDevShell
coyote-nix.lib.mkApp
```

## Low-level hardware stage

`mkCoyoteHwStagePackage` runs one Coyote hardware stage: configure with CMake, execute caller-provided build commands, check expected artifacts, and install caller-selected outputs.

```nix
let
  tools = coyote-nix.lib.mkTools {
    inherit pkgs coyoteRoot xilinxShareRoot;
  };
in
coyote-nix.lib.mkCoyoteHwStagePackage {
  inherit pkgs tools coyoteRoot xilinxShareRoot;
  hwSource = ./hw;
  pname = "my-u280-stage";
  platform = "u280";
  coyotePlatform = "ultrascale";
  xilinxVersion = site.boards.u280.xilinxVersion;
  buildCommands = [ "make project" "make bitgen" ];
  expectedPaths = [ "bitstreams/cyt_top.bit" ];
}
```

## Board-flow hardware packages

`mkCoyoteBoardPackages` builds conventional Coyote board flows for supported boards. It encodes Coyote mechanics such as checkpoint handoff, synth/routed/bitgen stages, final artifact installation, and simulation runtime export. It does not choose Xilinx versions; those must be supplied by the caller.

```nix
coyote-nix.lib.mkCoyoteBoardPackages {
  inherit pkgs tools coyoteRoot xilinxShareRoot;
  hwSource = ./hw;
  pnamePrefix = "my-project";
  projectName = "my-project";

  boards = {
    u280 = {
      xilinxVersion = site.boards.u280.xilinxVersion;
      simXilinxVersion = site.boards.u280.simXilinxVersion;
    };

    v80 = {
      xilinxVersion = site.boards.v80.xilinxVersion;
      simXilinxVersion = site.boards.v80.simXilinxVersion;
    };
  };
}
```

This produces public packages named by default:

- `<pnamePrefix>-u280-static`
- `<pnamePrefix>-u280`
- `<pnamePrefix>-u280-sim` when `simXilinxVersion` is supplied
- `<pnamePrefix>-v80`
- `<pnamePrefix>-v80-sim` when `simXilinxVersion` is supplied

Intermediate synth/routed derivations are internal dependencies of those outputs.

## Driver package matrix

`mkCoyoteDriverPackages` builds the conventional Coyote driver package matrix for a set of site-provided host kernels and target platforms:

```nix
coyote-nix.lib.mkCoyoteDriverPackages {
  inherit pkgs coyoteRoot;
  driverKernels = site.driverKernels;
  targetPlatforms = site.targetPlatforms;
}
```

By default this produces packages named:

```text
coyote-driver-<targetPlatform>-<hostName>
```

The site flake still owns host inventory and kernel policy; this helper only encodes the generic package-matrix mechanics.

## Dev shell board context

`mkCoyoteDevShell` accepts an optional `board` attrset, such as one supplied by a site flake. When present, it fills the Coyote board defaults used by the shell:

```nix
coyote-nix.lib.mkCoyoteDevShell {
  inherit pkgs tools coyoteRoot;
  withXilinx = true;
  board = site.boards.u280;
  fpgaPackage = "my-project-u280";
  fpgaArtifact = "cyt_top.bit";
}
```

Explicit arguments still override board-derived defaults. The expected board fields are:

```nix
{
  board = "u280";
  coyotePlatform = "ultrascale";
  targetPlatform = "ultrascale_plus";
  partHint = "xcu280";
  xilinxVersion = "...";
}
```

## Deployment helpers

Deployment helpers do not bake in project package names. A consuming project can set defaults through environment variables such as:

```sh
export COYOTE_NIX_ULTRASCALE_FPGA_PACKAGE=my-u280-package
export COYOTE_NIX_VERSAL_FPGA_PACKAGE=my-v80-package
export COYOTE_NIX_ULTRASCALE_FPGA_ARTIFACT=cyt_top.bit
export COYOTE_NIX_VERSAL_FPGA_ARTIFACT=cyt_top.pdi
```

or pass explicit image paths to commands like `program-cli` and `deploy-hw`.
