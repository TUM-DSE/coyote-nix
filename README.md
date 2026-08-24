# coyote-nix

Reusable Nix tooling for Coyote FPGA development.

This repository provides generic Coyote/Xilinx/Nix mechanics that can be shared by Coyote-based projects. It does not encode a deployment site's Xilinx installation path or vendor tool version policy; consuming projects must pass those values in from their site configuration.

`coyote-nix` does not provide preconfigured Vivado/Vitis packages by itself. A consuming project must provide a Xilinx installation path via `xilinxShareRoot` when constructing tools or hardware builds.

## Coyote compatibility pin

The flake pins the exact Coyote revision used by its checks and exposes it as `lib.defaultCoyote`. Consumers should normally follow this tested source instead of selecting Coyote and `coyote-nix` independently:

```nix
coyote-nix.url = "github:TUM-DSE/coyote-nix/<revision>";
coyote.follows = "coyote-nix/coyote";
```

A consumer may point `coyote` elsewhere when it intentionally needs another source revision. Such an override is outside the default tested pairing. The default pin proves the declared source and package checks only; it does not by itself claim complete FPGA synthesis or routing acceptance.

## Scope

Provided here:

- Xilinx tool wrappers (`vivado`, `hw_server`, `vitis_hls`)
- common Coyote shell tools (`program-cli`, `deploy-hw`, `reconfigure-app`, driver lifecycle helpers, hot reset, hugepages)
- generic Coyote hardware stage derivation builder
- generic U280/V80 Coyote board-flow builders
- reusable U280/V80 two-stage PR shell-export and app-only builders
- rootable Vivado QoR/post-place timing-oracle reports with an optional rejecting implementation gate
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
coyote-nix.lib.defaultCoyote
coyote-nix.lib.defaultCoyoteRevision
coyote-nix.lib.mkCoyoteShellPackage
coyote-nix.lib.mkCoyoteV80StaticCheckpointPackage
coyote-nix.lib.mkCoyoteAppPackage
coyote-nix.lib.mkCoyoteDriverPackage
coyote-nix.lib.mkCoyoteDriverPackages
coyote-nix.lib.mkCoyoteDevShell
coyote-nix.lib.mkCoyoteSourceChecks
coyote-nix.lib.mkApp
```

## Low-level hardware stage

`mkCoyoteHwStagePackage` runs one Coyote hardware stage: configure with CMake, execute caller-provided build commands, check expected artifacts, and install caller-selected outputs. Its environment declares the Python/Jinja renderer and JSON tooling used by Coyote generation and package metadata.

`mkCoyoteSourceChecks { pkgs; coyoteRoot; }` returns reusable Nix checks for Coyote's generic resident-service control source contract: control-enabled/stream-only/disabled generation on U280 and V80, AXI-Lite splitter simulation, and host API compilation.

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

## Two-stage PR shell and application packages

`mkCoyoteShellPackage` builds an `EN_PR=1` shell and exports the locked shell contract. `mkCoyoteAppPackage` accepts that exact derivation, passes it to Coyote as `SHELL_PATH`, and builds only application partial artifacts with `BUILD_APP=1`.

```nix
shell = coyote-nix.lib.mkCoyoteShellPackage {
  inherit pkgs tools coyoteRoot xilinxShareRoot;
  hwSource = ./shell-hw;
  pname = "my-u280-shell";
  board = "u280"; # or "v80"
  xilinxVersion = site.boards.u280.xilinxVersion;
  cmakeFlags = [ "-DFPLAN_PATH=${./floorplan.xdc}" ];
};

app = coyote-nix.lib.mkCoyoteAppPackage {
  inherit pkgs tools coyoteRoot xilinxShareRoot;
  hwSource = ./app-hw;
  pname = "my-u280-app";
  shellPackage = shell;
};
```

The shell package contains `export.cmake`, `checkpoints/shell_routed_locked.dcp`, reports/checkpoints, boot and board-applicable partial artifacts, and compatibility metadata. The app package contains only `config_*` application partials, app-build reports/checkpoints, and metadata tied to the exact shell.

See [`docs/two-stage-packages.md`](docs/two-stage-packages.md) for the complete API, output layouts, board differences, compatibility contract, and consumer guidance.

The established `mkCoyoteBoardPackages` API and package names are unchanged; standalone non-two-stage consumers do not need to migrate.

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

Deployment helpers do not bake in or infer project package names. `program-cli` and `deploy-hw` require an explicit image path, either as a positional argument or via `FPGA_BITSTREAM`:

```sh
program-cli path/to/image.bit
FPGA_BITSTREAM=path/to/image.bit deploy-hw
```

A consuming project that has an unambiguous default image should provide its own wrapper that passes that image path to these generic tools.

`hw_server` and `program-cli` use platform-specific default ports so UltraScale+ and Versal sessions can coexist: `3121` for U280/UltraScale+ and `3122` for V80/Versal. Override with `COYOTE_NIX_HW_SERVER_PORT` or `HW_SERVER_PORT` for multiple cards of the same platform.

`hw_server` logs default to `$HW_SERVER_LOG`, then `$XDG_RUNTIME_DIR/hw_server-<port>.log`, then `/tmp/hw_server-$UID-<port>.log`. The wrappers pre-create logs with world-writable permissions where possible, and fall back to the per-user `/tmp` path if the requested log is not writable.

For hosts with multiple identical FPGA parts, site inventory should provide `FPGA_JTAG_TARGET` as a Vivado hardware-target substring (for example a cable serial). `program-cli` filters `get_hw_targets` by that value before selecting the single device matching `FPGA_PART_HINT`.

`deploy-hw` runs the manual sequence:

```sh
unload-driver
hot-reset
program-cli image.bit|image.pdi
hot-reset
set-hugepages
insert-driver [driver.ko] image.bit|image.pdi
```

It is only for full-device programming. Do not pass a U280 application `.bin` to `deploy-hw`; unsupported image types are rejected during preflight before the driver is unloaded or any hardware action begins.

With a compatible shell already programmed and its Coyote driver active, load one application partial into a vFPGA with:

```sh
reconfigure-app --device 0 --vfpga 0 path/to/vfpga.bin
```

Versal application `.pdi` files are accepted as well. `reconfigure-app` calls Coyote's existing `cRcnfg::reconfigureApp` path; it does not unload the driver, program through JTAG, reset PCIe, or select a shell. Use `--dry-run` to validate the image path and IDs without opening a Coyote device.
