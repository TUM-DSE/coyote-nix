# Optional U280 subdivision starting checkpoint

`mkCoyoteShellPackage` accepts:

```nix
subdivisionReference = {
  checkpoint = "${implementedParent}/checkpoints/shell_routed.dcp";
  checkpointSha256 = "<64 lowercase hexadecimal digits>";
  staticCheckpoint = "${referenceStatic}/static_routed_locked_u280.dcp";
  staticCheckpointSha256 = "<64 lowercase hexadecimal digits>";
};
```

Both artifacts must be immutable Nix inputs. The build verifies both SHA256
values and requires the current `staticPath/static_routed_locked_u280.dcp`
to have the reference static SHA256. A mismatch fails before dynamic linking.
Other boards are rejected. Omit the option (or set it to `null`) to retain the
ordinary outer flow and metadata.

This is **only a `pr_subdivide` starting checkpoint**, not an exported app shell
and not an incremental implementation reference. The old outer implementation
is replaced by the new logical shell and new seed synthesis in the existing
nested linking flow. Fresh outer link/place/route/validation are absent from
the final dependency graph. Nested implementation, route validation, DRC,
timing policy, strict-signoff gates and export remain unchanged. `metadata/shell.json` provenance and
`coyoteTwoStage.physical.subdivisionReference` record the artifact identities.

SHA256 equality proves integrity and static byte identity, **not DFX boundary
compatibility**. The caller must independently qualify the implemented parent
with the selected Coyote/Vivado flow, including part, outer RP, boundary and
static preservation checks. This API neither relaxes source compatibility nor
claims an arbitrary aggregate is reusable. No physical qualification is provided
by the lightweight checks in this repository.

Lightweight validation:

```
nix build .#checks.x86_64-linux.subdivision-reference --no-link
```

The checksum check tests acceptance and corruption of each of the parent,
reference static, and current static inputs. Evaluation fixtures with dummy
checkpoint bytes are not buildable FPGA examples.
