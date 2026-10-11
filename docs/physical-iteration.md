# Bounded physical iteration

Use separate stages to answer separate questions. A successful synthesis or place derivation is not timing qualification. Nothing in this workflow programs hardware or automatically starts route.

## Preserve a baseline before changing it

Record the exact frozen source inputs, board/part, clock constraints, RP geometry, Vivado version, and implementation stage. A Git HEAD alone is insufficient when using dirty worktree overrides. Keep the baseline linked, placed and routed stage outputs, not just the final bitstream or a report screenshot.

GC roots protect outputs on the machine where they are registered. Copying a root symlink to another host does not transfer the output or register protection there. Retain a portable inventory, explicitly transfer the listed outputs/closures with `nix copy`, verify the inventory, and register roots on the destination. Missing checkpoints must not silently trigger a rebuild.

## Compare and retain existing outputs

From this repository (or substitute a pinned flake reference for `.`):

```sh
nix run .#coyote-compare-physical -- /nix/store/BASELINE-STAGE /nix/store/CANDIDATE-STAGE \
  --json comparison.json
nix run .#coyote-retain-physical -- baseline.json /nix/store/BASELINE-STAGE
nix run .#coyote-retain-physical -- --check baseline.json
```

Use actual store output paths in place of the examples. The comparator verifies declared stage-artifact hashes, reads raw timing/route/DRC reports, and distinguishes place, route and validation evidence. Rejected validation outputs are useful diagnostics, not accepted designs. A successful comparison means the inputs are comparable, **not** that timing passed. Unknown or changed clock periods, stages, tool/part/source/constraint identities are explicitly non-comparable; deltas are descriptive only. Missing evidence remains visible. It is a report reader, not a replacement for integrated clock/exception inspection or a signoff gate.

Retention accepts already-existing stage outputs, registers indirect Nix GC roots beside the inventory, and records checkpoint/manifest identities. It refuses to overwrite an inventory or existing root. `--check` detects missing outputs, wrong/dangling/unregistered roots and identity drift without rebuilding or fetching. It is not a backup: transfer the original outputs explicitly before an original host disappears.

## V80 shell placement hints

`mkCoyoteShellPackage` accepts optional `placementHints` independently of `hwSource`, static input and synthesis flags:

```nix
placementHints.groups = [
  {
    name = "egress";
    cells = [ "inst_shell/inst_dynamic/service/egress_bank" ];
    sites = [ "SLICE_X124Y620" "SLICE_X125Y620" ];
  }
];
```

This is schema syntax, **not** a usable floorplan recommendation. Supply exact hierarchy and sufficient legal sites from the actual design. Cell selectors may name a hierarchy; generated names such as `output_queues[0].inst_output_queue` are literal, not glob patterns. Site lists can be generated using Nix expressions. The interface defaults to additive soft placement groups. Setting `placementHints.requirePlacement = true` instead requires the selected resident cells to remain in their admitted placement regions (`IS_SOFT=false`). It does not enable routing containment, modify hard RP geometry, change clocks/timing exceptions, or accept arbitrary XDC/Tcl. Required regions can fail placement if resources or connectivity cannot be satisfied; never use them to waive timing or DRCs. Default manifests retain API v1; required-placement manifests use API v2.

The V80 source-static full-shell flow can opt into `placementHints.allowUnplacedStatic = true` (manifest API v3). This permits named descendants of `inst_static` only when every selected primitive is still unplaced. It does not permit the static insertion root itself, clock resources, cells with an existing location, fixed cells/ancestors, RP overlap, or existing Pblock membership/site collisions. A placed or locked static reference remains protected even if a fixed-location flag is unset. This option is for initial placement of synthesized static fabric, not relocation of an implemented static image.

The place-stage admission checks reject missing/overlapping selectors, protected static/RP/fixed cells, existing Pblock ownership and site collisions before applying groups. A changed hint changes the place recipe and all downstream derivations; synthesis, implementation inputs, link and opt remain reusable. The stage manifest retains the hint input and its identity. This initial interface is for independently staged **V80 shell placement**, not U280 or app-only implementation.

Keep the hint declaration outside the fileset passed as `hwSource`. Keeping an experimental XDC in that fileset or in common CMake flags still invalidates synthesis. Existing hard geometry and synthesis timing constraints must stay in their normal inputs.

## Choose the cheapest relevant experiment

- **Logic change:** behavioral tests, then representative synthesis. An isolated black-box RP interface cannot prove physical boundary timing.
- **Placement-only hint:** reuse synthesis/link with the separate placement-hint API. Do not edit RTL, timing constraints, hard RP geometry, or the common hardware source fileset to express a soft placement experiment.
- **Clock, timing-exception or RP geometry change:** this is not a placement-only hint. Use the normal fully invalidated flow and review compatibility.
- **Report-only analysis:** compare retained stage outputs without Vivado or implementation.

The three-slot QShell profile historically included every floorplan in its hardware fileset and passed the floorplan flag to static/shell synthesis. Merely enabling a new API does not repair that dependency: consumers must leave their hard geometry unchanged and move only experimental soft hints outside the synthesis source/flags. Consumer migration is separate from this library change.

## Placement is a decision boundary

Build only the selected `coyoteTwoStage.physical.units.<unit>.place` output and retain it. Compare like stages with identical part, tool and clocks. Check every relevant region and both sides of added boundaries, including reverse ready/credit paths, lifecycle/control fanout, congestion and clock/exception coverage. A local improvement can make another path worse.

Do not proceed to route merely because placement completed or a selected path improved. First verify that the intended physical change actually happened and that no known structural blocker remains. Placement delay is still an estimate; a route experiment may be justified to resolve a specific uncertainty, but its cost and question should be explicit.

Full route and existing strict setup/hold, route, DRC, DFX and coverage gates remain the acceptance authority. Comparisons and soft hints never waive those gates.
