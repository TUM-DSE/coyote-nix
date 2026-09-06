# Software deployment without rebuilding FPGA images

Keep an accepted full shell and its matching partial, metadata, source identities
and SHA256 together. Updating the driver/host library is not permission to update
the hardware Coyote input or reuse timing acceptance for a different image.

## Driver package and host interface

`mkCoyoteDriverPackage` accepts `variant = "legacy"` (default), `"versal"`, or
`"ultrascale_plus"`. An explicit variant must match `targetPlatform`. `moduleName`
defaults to `coyote_driver` for legacy and `coyote_driver_<variant>` otherwise;
it must agree with the compiled identity, not rename a legacy binary.
`mkCoyoteDriverPackages` accepts the same arguments as constants or functions of
`{ hostName, targetPlatform }`. Existing legacy package names remain unchanged.

Use a separately pinned host/driver `coyoteRoot` containing the variant support;
do not advance a shell's hardware source just to obtain software fixes. Rebuild
C++ consumers together with the host library because namespace state changes
object layouts. Select the matching `COYOTE_DEVICE_PREFIX` before constructing
objects; explicit namespaces must never open/chmod another family's mutexes.

Example (in the consuming flake, with its declared kernel):

```nix
mkCoyoteDriverPackage {
  inherit pkgs driverKernel;
  coyoteRoot = inputs.coyoteHost;
  pname = "coyote-driver-versal-target";
  targetPlatform = "versal";
  variant = "versal";
}
```

The package retains `module-name`, `kernel-store-path`, `kernel.config` and a
top-level module symlink. Use that top-level path with `insert-driver`, not a
renamed loose `.ko`. Set `COYOTE_MODULE_NAME=coyote_driver_versal` and an explicit
`FPGA_BDF` for both insertion and removal. Default module selection stays legacy.
`COYOTE_DRIVER_PACKAGE` resolves the selected module basename.

Insertion checks internal module name, running release, the exact
`/run/booted-system/kernel` target and byte-identical decompressed
`/proc/config.gz` against packaged evidence **before insmod**. A switched
`/run/current-system` is not boot compatibility evidence. Missing evidence fails
closed; select/build the authoritative declared kernel matching the actual boot,
not a same-release guess. This NixOS-specific guard does not certify arbitrary
non-NixOS loose module installation. Module signing/lockdown policy may impose
additional requirements. Probe/binding must pass independently of insmod's rc;
check required BARs/MSI-X allocation and the expected device/sysfs nodes.

Removal requires explicit `FPGA_BDF` and never unbinds or unloads a foreign
module. It refuses module-wide removal if the selected module owns another
endpoint. A missing BDF fails closed rather than choosing an ambiguous legacy
family or removing every endpoint. It does not force removal,
mask errors, repair a wedged kernel, or prove DMA has drained. Legacy and explicit
modules of the same family still compete for the same PCI IDs.

## Programming and PCI readiness: operator recipe, not automatic recovery

1. Record target hostname, endpoint and verified immediate bridge/subordinate bus,
   all sibling ownership, supported image identity, JTAG cable, part and DNA.
   Verify immutable full-shell/partial hashes and compatibility metadata.
2. Use the consuming flake's XDB environment. Inspect the **installed hw_server
   version separately from the Python SDK version**: a 2025.2 SDK does not prove
   a 2025.2 server is installed. Select the observed supported server/version,
   explicit target and finite owned server lifetime. Do not start extra servers
   or silently switch backends when target selectors are unsupported.
3. Program the full matching shell with the ordinary full-program reset behavior,
   then the matching application partial with **explicit `skip_reset=True`**.
   Partial no-reset is not the default for full-shell programming. The preserved
   SDK supports this flag; fail before mutation if the selected API does not.
4. After full programming, perform the separately authorized normal PCIe
   secondary-bus reset on the verified upstream bridge. Preserve/read back its
   original BRIDGE_CONTROL, assert SBR for the documented 0.5 seconds and restore
   conditionally in a finally/trap path (never overwrite a concurrent change).
   Endpoint removal/re-enumeration and reset require sole affected-bus ownership.
5. Bound configuration readiness by an explicit operator timeout. Link-active is
   not configuration-ready; require a valid nonzero/non-FFFF vendor/device read.
   Where the endpoint was removed, use the verified subordinate-bus discovery
   path only after readiness/settling policy, then gate BAR0/2/4, bridge windows,
   binding and nodes. A delayed Clara rediscovery succeeded after an immediate
   attempt failed: that proves eventual readiness, **not a mandatory 276s sleep**.
   Stop at timeout/failure; do not turn one scan into an unbounded retry loop.
6. Compare unrelated PCI resource/driver identities and kernel health with the
   pre-attempt baseline. An unassigned MSI-X BAR is a resource/probe blocker,
   not a reason to widen the PCI ID table or invent a register offset.

**Current helper boundary:** existing `hot-reset` requires an enumerated endpoint
and defaults to a global rescan (including sibling-function removal).
`deploy-hw` invokes that helper. They are **not** the absent-endpoint/scoped Clara
recipe above; do not invoke them blindly for that recovery. This change adds no
automatic PCI reset, root-bus scan, resource-alignment policy or bridge removal.
The exceptional successful Clara policy (`12@0000:80:01.1`, saved/restored empty
policy, rootport-only remove/readd and one root80 scan) required explicit operator
authorization because root80 contains unrelated ptdma/xhci siblings. It must not
become a default. Never use manual BAR writes or broaden scan scope silently.

Minimum upstream XDB change still needed: expose explicit full versus no-reset
partial programming through the public program API; enforce observed cable/part/
DNA selectors in each backend; distinguish installed server and SDK versions;
propagate finite operation deadlines and report selected identity/hash/reset
mode. The approved SDK `device.program(image, skip_reset=True)` helper remains
reference evidence, not a license to mutate an external XDB checkout or claim
backend selector parity. Scoped PCI discovery/reset belongs to a separately
reviewed deployment helper, not an inferred programming side effect.

## Transfer and failed requests

Use the site's known working Nix store transport (Clara used
`nix copy --to ssh://clara ...`) with verified SSH host keys. Distinguish SSH
public-key denial from a store signature/trusted-user error. For signature
rejection, report transport/store path and request an approved signed/trusted
route; never add blanket `--no-check-sigs` or alter global trust settings.

A timed-out DMA request is a failed hardware/transport epoch. Stop submitting;
software page unpin, context retirement and workqueue drain do **not** cancel a
queued hardware RX descriptor. Do not immediately retry with a recycled CTID.
The proven fallback used the identical full shell plus no-reset partial and
supported PCI recovery before starting a fresh context; SBR alone is not proven
to clear dynamic FIFOs. A general safe DMA cancellation/drain protocol remains
unimplemented. Do not promise safe cleanup after arbitrary completion loss.

Resident-control all-ones/ABI mismatch remains unresolved. It is not proof that
telemetry is absent. Stop at identity rejection before writes; require the
actual aperture/access cause before changing driver addresses or RTL. Optional
cross-task notifier locking and arbitrary hot removal are also outside the
qualified lifecycle scope.
