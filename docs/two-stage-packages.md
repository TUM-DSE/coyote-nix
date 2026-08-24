# Two-stage Coyote shell/application packages

`coyote-nix` exposes two generic helpers for Coyote's reusable `BUILD_SHELL` -> `BUILD_APP` flow:

- `lib.mkCoyoteShellPackage`: build, route, lock, and export an `EN_PR=1` shell.
- `lib.mkCoyoteAppPackage`: compile an application against one exact shell package with `BUILD_APP=1`.

They support `u280` and `v80`. They are additive: `mkCoyoteBoardPackages` and all of its existing package names and conventional full-image behavior remain unchanged.

## V80 custom static checkpoints

A provider-enabled or otherwise custom V80 static build emits generic internal checkpoints as `checkpoints/static/static_synthed.dcp` and `checkpoints/static_routed_locked.dcp`. Coyote's Versal dynamic flow deliberately selects immutable board/PCIe-specific names instead. Normalize a custom static package before supplying its `checkpoints` directory to a shell build:

```nix
v80Static = coyoteNix.lib.mkCoyoteV80StaticCheckpointPackage {
  inherit pkgs;
  staticPackage = customV80StaticBuild;
  pcieGeneration = 5; # 4 and 5 are supported
};
```

The result retains the complete source package and adds both `static_synthed_v80_genN.dcp` and `static_routed_locked_v80_genN.dcp`, plus checked provenance under `metadata/v80-static-checkpoints.json`. This prevents a custom static build from succeeding only for the subsequent dynamic shell flow to fail on a missing board-specific checkpoint alias.

## Shell API

```nix
coyote-nix.lib.mkCoyoteShellPackage {
  inherit pkgs tools coyoteRoot xilinxShareRoot;
  xilinxShell = xilinx-shell; # optional

  hwSource = ./shell-hw;
  pname = "project-u280-shell";
  version = "0.1.0"; # optional

  board = "u280"; # "u280" or "v80"
  xilinxVersion = site.boards.u280.xilinxVersion;
  staticPath = "${coyoteRoot}/hw/checkpoints"; # optional default

  cmakeFlags = [
    "-DFPLAN_PATH=${./u280-floorplan.xdc}"
    # Shell/application interface and service configuration belongs here.
  ];

  # Optional JSON-serializable caller metadata.
  provenance = {
    projectRevision = self.rev or self.dirtyRev or "dirty";
  };

  # Optional fast synthesized-shell analysis before DFX linking/placement.
  synthesisAnalysis = {
    enable = true;
    enforce = true;
    rejectSetupWnsBelow = 0.0;
    passSetupWnsAtLeast = 0.5;
    maximumLogicLevels = null;
    maxPaths = 100;
    maxFanoutNets = 100;
  };

  # Optional stronger predictive gate before full-quality implementation.
  timingOracle = {
    enforce = true;
    rejectRqaBelow = 3;
    passRqaAtLeast = 4;
    maxPaths = 100;
  };
}
```

The helper appends and owns these CMake settings, so caller flags cannot accidentally select a different flow:

```text
FDEV_NAME=<board>
BUILD_APP=0
BUILD_STATIC=0
BUILD_SHELL=1
EN_PR=1
EN_SHELL_PBLOCK=1  # U280
EN_SHELL_PBLOCK=0  # V80
STATIC_PATH=<staticPath>
```

A stable config-0/seed application and an application floorplan still have to be supplied by the consuming Coyote hardware project.

### Board-specific shell graph

| Board | Internal stages | Boot image | Shell partial | Seed app partial |
|---|---|---|---|---|
| U280 | optional shell synthesis analysis -> seed synthesis -> routed shell -> dynamic PR flow -> bitgen | `cyt_top.bit` | `shell_top.bin` | `config_*/vfpga_*.bin` |
| V80 | optional shell synthesis analysis -> seed synthesis -> Versal dynamic PR flow -> bitgen | `cyt_top.pdi` | none (nested DFX is unsupported) | `config_*/vfpga_*.pdi` |

Both flows run Coyote's `make app` dynamic target after synthesis (and, for U280, after ordinary shell routing). Bit generation is invoked from the generated `bitgen.tcl` directly, retaining the existing coyote-nix handling for Vivado failures after artifact creation.

### Fast synthesized-shell analysis

When `synthesisAnalysis.enable = true`, the shell package exposes:

- `synthesisAnalysisRaw`: synthesizes only the resident shell and runs Coyote's `make synthesis_analysis`; it does not synthesize the seed application or read the external static checkpoint. It retains the shell DCP plus estimated setup/hold timing, critical paths, utilization, check-timing, and high-fanout reports.
- `synthesisAnalysis`: applies configurable WNS and optional logic-level policy in a lightweight derivation and retains `metadata/synthesis-analysis.json` plus links to the raw reports/checkpoint.
- `synthesisGate`: accepts `PASS` and `MARGINAL`, and rejects `FAIL` while preserving the inspectable analysis output.

Policy is separate from Vivado evidence so threshold changes do not repeat shell or seed synthesis. The ordinary `synth` stage reuses the already synthesized resident-shell DCP and synthesizes only the seed application, independent of policy. When enforcement is enabled, the stronger linked oracle checks `synthesisGate` before starting. The external static checkpoint is introduced only by that linked oracle/implementation flow, so resident-shell and seed synthesis do not wait for static realization.

A negative post-synthesis setup WNS is a conservative early rejection signal, not routed evidence. Positive estimated slack does not account for placement or congestion and must proceed through the linked oracle and full implementation.

Useful aliases are:

```nix
packages.${system}.project-v80-shell-synthesis-analysis =
  shell.coyoteTwoStage.stages.synthesisAnalysis;
packages.${system}.project-v80-shell-synthesis-check =
  shell.coyoteTwoStage.stages.synthesisGate;
```

### Predictive timing oracle

Every shell package exposes two additional diagnostic stages through `coyoteTwoStage.stages`:

- `timingOracle`: copies the synthesis result, runs Coyote's `make timing_oracle`, and retains linked/optimized checkpoints, optional `RuntimeOptimized` placement, RQA reports/CSV data, estimated timing, and enriched `metadata/timing-oracle.json`.
- `timingGate`: accepts `PASS` and `MARGINAL`, but exits nonzero for `FAIL` while printing the oracle store path and compact reasons.

The oracle stage itself succeeds for all valid classifications so a rejected candidate's reports can be installed and durably rooted. Build the oracle output explicitly before the gate when diagnostics must survive a rejection. If `timingOracle.enforce = true`, the U280 routed-shell stage or V80 dynamic stage depends on `timingGate`; normal full-quality implementation starts only after the predictive candidate is not classified `FAIL`.

The cheap placement checkpoint is never supplied to sign-off implementation. The normal flow starts again from the synthesis/link boundary and retains final route, DRC, and timing as the physical authority.

Versal assesses the fully linked application-DFX configuration 0. UltraScale+ assesses the linked shell before nested DFX subdivision, because subdivision follows ordinary shell routing; calibrate board-family thresholds independently.

Useful aliases in a consuming flake are:

```nix
packages.${system}.project-v80-shell-timing-oracle =
  shell.coyoteTwoStage.stages.timingOracle;
packages.${system}.project-v80-shell-timing-check =
  shell.coyoteTwoStage.stages.timingGate;
```

### Shell output

```text
$out/
├── export.cmake
├── checkpoints/
│   └── shell_routed_locked.dcp
├── reports/
├── bitstreams/
│   ├── cyt_top.bit|pdi
│   ├── shell_top.bin        # U280 only
│   └── config_*/            # seed application partials
└── metadata/
    ├── shell.json
    ├── compatibility-id
    └── artifacts.json
```

All generated reports, checkpoints, debug probes, and board-applicable bitstream artifacts are retained, not only the minimum files shown above.

## App API

```nix
coyote-nix.lib.mkCoyoteAppPackage {
  inherit pkgs tools coyoteRoot xilinxShareRoot;
  xilinxShell = xilinx-shell; # optional

  hwSource = ./app-hw;
  pname = "decoder-u280-app";
  version = "0.1.0"; # optional

  # Must be the derivation returned by mkCoyoteShellPackage.
  shellPackage = shell;

  # Optional assertion. Normally inferred from shellPackage.
  board = "u280";

  cmakeFlags = [
    # Application-source/configuration flags only.
  ];

  provenance = {
    applicationRevision = self.rev or self.dirtyRev or "dirty";
  };
}
```

The board and exact Xilinx version are inherited from `shellPackage`. An explicitly supplied `board` must match. The helper appends:

```text
FDEV_NAME=<shell board>
BUILD_APP=1
BUILD_STATIC=0
BUILD_SHELL=0
EN_PR=1
EN_SHELL_PBLOCK=<shell board value>
SHELL_PATH=<exact shellPackage store path>
```

The Nix dependency and the `SHELL_PATH` value therefore identify the same immutable package. Before each build stage, the helper verifies that the package has `export.cmake`, `shell_routed_locked.dcp`, valid shell metadata, and matching artifact hashes.

The app graph is `synth -> app route -> bitgen` on both boards. Its installed bitstream tree is deliberately filtered to `config_*` directories, so it cannot publish `cyt_top` boot images or `shell_top` partials.

### App output

```text
$out/
├── checkpoints/             # generated by this BUILD_APP invocation
├── reports/                 # generated by this BUILD_APP invocation
├── bitstreams/
│   └── config_*/
│       └── vfpga_*.bin|pdi
└── metadata/
    ├── app.json
    ├── application-id
    ├── artifacts.json
    ├── shell.json            # exact shell metadata copy
    └── shell-compatibility-id
```

`export.cmake`, the locked shell DCP, shell partials, and full boot images are not copied into the app package.

## Compatibility and provenance

The shell compatibility ID is SHA-256 over a versioned domain plus:

- board and FPGA architecture;
- exact Xilinx version string;
- SHA-256 of `export.cmake`;
- SHA-256 of `checkpoints/shell_routed_locked.dcp`.

`shell.json` also records the FPGA part, flow settings, Coyote source store path, hardware source store path, static checkpoint path, caller provenance, and a hash manifest for installed artifacts. Its generic `applicationTopology` object records the exported region count, streams per region, application-interface version, and AXI data width. When supported by the Coyote source, the `residentService` object records the external service name and stream ABI, optional per-region slot-status presence/width, and optional control presence, ABI, interface version, base, size, address width, and data width. When logical co-processor ports are exported, the `coprocessor` object records the processor-neutral stream and MMIO dimensions, binding-generation width, and immutable physical-provider inventory. Processor providers remain separate from logical application roles, and an export without co-processor fields receives a disabled object with zero dimensions. Older Coyote exports receive disabled optional objects with zero dimensions, but must still export positive application-topology dimensions.

`app.json` records:

- the exact shell package store path;
- the shell compatibility ID and both shell-contract artifact hashes;
- app and shell Coyote source paths, including whether they match;
- application hardware source and caller provenance;
- hashes of all installed app partials, reports, and checkpoints.

The application ID binds the shell compatibility ID to the canonical app artifact-manifest hash. Runtime/deployment tooling can compare `metadata/shell-compatibility-id` with the active shell's `metadata/compatibility-id` before loading a partial.

The helper records a Coyote-source mismatch in provenance but does not reject it, since a later Coyote revision may contain app-flow-only fixes. Consumers should normally use the exact same pinned Coyote source for shell and app builds.

## Cross-flake consumer pattern

Export the shell derivation as a normal package from the shell-owning flake:

```nix
packages.${system}.u280-shell = coyote-nix.lib.mkCoyoteShellPackage { ... };
```

A downstream application flake should follow the same pinned Coyote and coyote-nix inputs, then pass that package directly:

```nix
app = inputs.coyote-nix.lib.mkCoyoteAppPackage {
  inherit pkgs tools xilinxShareRoot;
  coyoteRoot = inputs.coyote;
  hwSource = ./hw;
  pname = "decoder-u280-app";
  shellPackage = inputs.shell-owner.packages.${system}.u280-shell;
};
```

Pin pushed Git revisions in committed flake inputs. Local `path:` overrides are suitable only for command-line validation and must not be written to a lock file.

## Coyote prerequisites and current boundaries

These helpers package and validate Coyote's generated flow; they do not replace missing Coyote implementation support. The selected Coyote revision must provide:

1. a working U280 and V80 `EN_PR=1` shell dynamic target that writes `shell_routed_locked.dcp`;
2. a working `BUILD_APP=1` target for the selected architecture;
3. `bitgen.tcl` support for U280 `.bin` and V80 `.pdi` application partials;
4. an `export.cmake` containing every application-interface and service ABI field a later app configure needs.

The accepted reconnaissance base still marked complete V80 app-only support TODO, declared some incorrect U280 artifact names/paths, and omitted ABI-defining fields from `export.cmake`. Consume a Coyote revision containing those source-side fixes. The coyote-nix helpers use the real board artifact names and call generated bitgen Tcl directly, but they cannot repair an incomplete V80 route flow or export contract in the selected Coyote source.

No helper performs programming, PCIe access, driver insertion, or any other hardware operation. Flake evaluation and contract checks require no Xilinx installation or physical FPGA.

## Hardware-free validation

Run the repository checks with:

```sh
nix flake check --no-write-lock-file
```

The checks preserve the legacy board-package name matrix, evaluate U280/V80 shell and app graphs, reject a mismatched app/shell board, verify board artifact contracts, exercise manifest generation, parse generated build/install shell phases, and run shellcheck. They instantiate but do not build FPGA derivations.
