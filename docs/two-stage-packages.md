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

The package graph uses immutable physical stages rather than Coyote's legacy aggregate `make shell`/`make app` targets. U280 first implements the outer shell and then configuration 0; V80 implements configuration 0 directly. Bit generation remains a separate final image stage and retains the existing handling for Vivado failures after artifact creation.

### Immutable physical stages

Shell and application constructors accept an optional implementation recipe:

```nix
implementation = {
  resources.cores = 8;
  directives = {
    opt = "Explore";
    place = "AggressiveExplore";
    physOpt = "AggressiveExplore";
    route = "AggressiveExplore";
    postRoutePhysOpt = "AggressiveExplore";
    finalRoute = "";
  };
  enforceTiming = true;
  xilinxInstallationId = "site-manifest-sha256"; # recommended when available
  topology = { configurations = 1; regions = 1; };
};
```

Omitted directives reproduce the effective legacy `BUILD_OPT` board defaults. Repeated legacy CMake policy flags are interpreted with CMake's last-assignment-wins behavior. Cores, phase directives, timing policy, source/constraint/static identity, Coyote source, board/part, Xilinx version/installation identity, and the exact predecessor manifest all participate in stage identity.

The physical contract is available under `coyoteTwoStage.physical` and the rootable derivations under `coyoteTwoStage.stages`:

```text
inputs -> link -> opt -> place -> route -> validate -> validationGate -> [DFX finalize] -> image
```

`place` includes pre-route physical optimization. `route` keeps post-route physical optimization and its mandatory final reroute atomic. `validate` reopens the route read-only, retains route/timing/DRC evidence, and emits `accepted` or `rejected`; the separate gate rejects only after that evidence is rootable. Shell DFX locking/recombination runs afterward as an explicit `finalize` stage, so a finalization failure cannot destroy the retained validation result. Image generation requires an accepted validation/finalization manifest.

Each stage contains `metadata/stage.json` and `metadata/complete`. The manifest hashes every declared artifact and binds the exact phase, implementation unit, canonical context, predecessor manifest/outcome, strategy, and resources. Consumers validate and import only declared roles; undeclared files in a predecessor cannot leak into the next physical phase.

New package graphs use the strict `coyote-nix.implementation-stage/v2` manifest ABI; the validator retains read-only compatibility with historical v1 artifacts. Every non-input v2 stage must contain:

- `metadata/execution.json` and raw `metadata/gnu-time.txt` for build-command wall time, user/system CPU, peak RSS, requested cores, exit status, and post-command scratch size;
- `logs/command.stdout.log` and `logs/command.stderr.log` for the exact measured command scope;
- `metadata/telemetry.json`, using `coyote-nix.implementation-telemetry/v1`, with canonical integer units and explicit unavailable/not-applicable observations;
- phase-local timing and utilization reports for opt/place/route/validate, route status for route/validate, and bitstream DRC for validation. Physical-stage RQA is retained where safe, but is explicitly unavailable for U280 under Vivado 2023.2 because `report_qor_assessment` can terminate that tool process after successful optimization; request the separate advisory timing oracle for RQA experiments rather than risking a canonical checkpoint;
- `metadata/primary-tool.json` on image stages, preserving Vivado's original nonzero exit when the existing completion-marker exception accepts post-completion cleanup failure.

`recipeId` hashes context, phase, unit, predecessor recipe, strategy, and requested resources but excludes measured runtime. `manifestId` identifies the exact realized evidence and therefore includes telemetry and logs. FPGA realization is not assumed bit-for-bit deterministic: a cache stores one evidence-bearing realization of the pinned recipe, while the recipe ID remains stable for comparisons. Later implementation phases consume authoritative checkpoint/image roles, not normalized metrics or future selection policy.

Telemetry is factual rather than an acceptance decision. Validation still emits accepted/rejected evidence and the separate validation gate applies policy. Finalize/image telemetry describes only those commands; predecessor timing is not relabeled as a new measurement. A normally failed Nix derivation cannot publish `$out`, so transient tool/license/OOM failures remain retryable and may have only `nix log`/`--keep-failed` evidence. A future immutable failed-attempt bundle requires an explicit non-substitutable diagnostic mode rather than converting ordinary failures into cached successes.

The immutable packaged graph currently supports the QShell MVP topology of exactly one configuration and one region. The legacy Coyote aggregate flow remains available for multi-configuration/multi-region projects until per-unit DFX bundle staging is added; immutable package constructors reject any explicitly different topology and Coyote's staged link target verifies the generated topology before invoking Vivado.

### Fast synthesized-shell analysis

Every shell package exposes `residentShellSynthesis`, which synthesizes only the resident shell into an independently rootable checkpoint without synthesizing the seed application or reading the external static checkpoint. This is the immutable predecessor for read-only synthesis analysis and later seed synthesis, so an analysis-script or assessment failure does not discard successful expensive synthesis.

When `synthesisAnalysis.enable = true`, the shell package also exposes:

- `synthesisAnalysisRaw`: consumes `residentShellSynthesis` and runs only Coyote's `make synthesis_analysis`. It retains the shell DCP plus estimated setup/hold timing, critical paths, utilization, check-timing, and high-fanout reports.
- `synthesisAnalysis`: applies configurable WNS and optional logic-level policy in a lightweight derivation and retains `metadata/synthesis-analysis.json` plus links to the raw reports/checkpoint.
- `synthesisGate`: accepts `PASS` and `MARGINAL`, and rejects `FAIL` while preserving the inspectable analysis output.

Policy is separate from Vivado evidence so threshold changes do not repeat shell or seed synthesis. The assessment helper accepts both `resident-shell-synthesis` and focused `module-out-of-context` raw evidence, allowing consumers to reuse the same classification/check contract for module checks. The ordinary `synth` stage consumes `residentShellSynthesis` directly and synthesizes only the seed application, independent of analysis evidence or policy. The linked oracle is also independently invocable and does not require the synthesis check. The external static checkpoint is introduced only by that linked oracle or canonical implementation flow, so resident-shell and seed synthesis do not wait for static realization.

The historical `synthesisAnalysis.enforce` field remains accepted and recorded for source compatibility, but it does not insert a diagnostic check into canonical implementation. Invoke `synthesisGate` explicitly when a predictive classification should control an operator's decision.

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

The oracle stage itself succeeds for all valid classifications so a rejected candidate's reports can be installed and durably rooted. Build the oracle output explicitly before its check when diagnostics must survive a rejection. The historical `timingOracle.enforce` field remains accepted and recorded for source compatibility, but neither U280 nor V80 canonical implementation depends on `timingGate`.

The cheap placement checkpoint is never supplied to canonical implementation. A requested full build starts from the normal synthesis/link boundary regardless of diagnostic classification; final route, DRC, setup, hold, and validation remain the physical authority.

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

The app graph is `synth -> immutable input bundle -> link -> opt -> place -> route -> validate -> gate -> image` on both boards. Its installed bitstream tree is deliberately filtered to `config_*` directories, so it cannot publish `cyt_top` boot images or `shell_top` partials. Intermediate checkpoints and reports belong to their independently rootable stage outputs; the final package retains the accepted routed checkpoint, validation evidence, application partials, and compatibility metadata.

### V80 placement portfolios

A V80 application may branch two or three explicitly declared placement candidates from its one canonical optimized checkpoint:

```nix
implementation.placementPortfolio = {
  candidates = [
    {
      id = "balanced";
      placeDirective = "SSI_BalanceSLRs";
      physOptDirective = "AggressiveExplore";
      resources = {
        cores = 4;
        ramMiB = 65536;
        scratchMiB = 131072;
        licenses = [ "vivado-implementation" ];
      };
    }
    {
      id = "spread";
      placeDirective = "SSI_SpreadLogic_high";
      physOptDirective = "Explore";
      resources = {
        cores = 4;
        ramMiB = 65536;
        scratchMiB = 131072;
        licenses = [ "vivado-implementation" ];
      };
    }
  ];
  routeCandidates = [ ]; # explicitly select at most two only after diagnosis
  recommendationPolicy = {
    schemaVersion = 1;
    api = "coyote-nix.placement-recommendation-policy/v1";
    maxRouteCandidates = 2;
    weights = {
      rqa = 1000000;
      setupSlackPerPs = 1;
      logicLevelPenalty = 100;
      congestionPenalty = 1000;
    };
  };
};
```

Every candidate has an independently rootable place stage and normalized diagnosis under `coyoteTwoStage.stages.placementCandidates.<id>`. Place stages retain raw congestion, complexity, logic-level, high-fanout, timing, utilization, and RQA evidence. `diagnosis` converts supported observations into `coyote-nix.placement-diagnosis/v1` with canonical integer units and explicit unavailable states.

`placementRecommendation` ranks the complete candidate set under the separately versioned policy and emits an advisory-only recommendation. It never causes Nix to route a newly selected candidate. The user must copy at most two candidate IDs into `routeCandidates` and evaluate/build those explicit route/validate/gate outputs in a second step. Candidate count, identifiers, resource declarations, and selection bounds are rejected during evaluation. The ordinary canonical route and all final DRC/setup/hold/image gates remain unchanged.

### U280 incremental implementation

U280 shell and application packages may use one explicitly selected prior accepted validation stage as an experimental Vivado incremental reference:

```nix
implementation.incrementalReference = previous.coyoteTwoStage.stages.validate;
```

The reference must be an immutable Nix derivation. At build time coyote-nix validates its complete stage manifest, accepted outcome, checkpoint hash, U280 part, topology, flow, and exact Vivado installation identity. It then records `metadata/incremental-reference.json`, loads the declared checkpoint through `read_checkpoint -incremental`, and retains place/route incremental-reuse reports.

The resulting `coyoteTwoStage.stages.incremental.{opt,place,route,validate,gate}` branch is separate from the ordinary clean stages. It is an iteration experiment and has `signoffAuthority = false`; final shell/application images continue to consume only the clean validation path. The first physical pilot must verify checkpoint-state continuity and reuse reporting under the pinned Vivado 2023.2 U280 toolchain before runtime or QoR improvements are claimed.

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

`shell.json` also records the FPGA part, flow settings, Coyote source store path, hardware source store path, static checkpoint path, caller provenance, and a hash manifest for installed artifacts. Its generic `applicationTopology` object records the exported region count, total and host-visible streams per region, application-interface version, and AXI data width. When supported by the Coyote source, the `residentService` object records the external service name and stream ABI, optional per-region slot-status presence/width, optional resident peer-endpoint ownership/version/count, and optional control presence, ABI, interface version, base, size, address width, and data width. The separate `peerTransport` object records enablement, generic interface version, owner, backend, connector, declared flow-control mode, link/endpoint counts, and stream width; enabled transports with incomplete metadata are rejected rather than inferred from a backend name. When logical co-processor ports are exported, the `coprocessor` object records the processor-neutral stream and MMIO dimensions, binding-generation width, and immutable physical-provider inventory. Processor providers remain separate from logical application roles, and an export without co-processor fields receives a disabled object with zero dimensions. Older Coyote exports receive disabled optional objects with zero dimensions, but must still export positive application-topology dimensions.

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
