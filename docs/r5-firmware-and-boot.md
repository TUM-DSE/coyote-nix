# R5 firmware and boot composition

Coyote-Nix separates implemented hardware, R5 firmware, and deployable boot
images. A firmware-only change must not rebuild the FPGA hardware platform.

## Embedded tools

`mkTools` exposes separate version-selected `tools.armr5` and `tools.bootgen`
closures, plus their `tools.embedded` development-shell union. Set
`COYOTE_NIX_XILINX_VERSION`; each wrapper resolves both the executable and
component environment from that exact Vitis installation and runs it through
the supplied `xilinx-shell`. Consumers should pass the site shell through
`mkTools.extraRuntimeInputs` so builds do not depend on an ambient command.

`tools.r5-bif` provides `coyote-r5-bif`, a device-free renderer and checker for
the one accepted initial composition: one metacharacter-free relative base PDI
followed by exactly one `core=r5-0` ELF in the fixed TCM-owning subsystem
`0x1c000000` with `delay_handoff`. It rejects absolute/parent-relative paths,
syntax-bearing names, alternate subsystem IDs, and any additional or changed
partition.

## Firmware package

`mkCoyoteR5FirmwarePackage` builds a consumer-owned freestanding source tree
with the selected Vitis R5 compiler. Its platform contract declares the Xilinx
version, processor/core, ATCM/BTCM ranges, entry, vector/status layout, required
symbols, and fixed stack symbols. The package rejects dynamic, relocated,
hard-float, non-ARM, non-executable, or out-of-TCM ELFs and retains:

- the ELF and linker map;
- ELF headers, attributes, section/program tables, symbols, sizes, and
  disassembly;
- the exact platform source contract and validation report;
- content hashes plus independent firmware and platform-contract identities;
- an optional caller-supplied 256-bit runtime identity, retained in metadata
  when firmware publishes the same source/build identity through hardware.

These checks prove ELF shape and bounds. They do not prove that an XSA grants
TCM ownership or that hardware boots.

## Boot package

`mkCoyoteR5BootPackage` accepts a hardware platform package and a firmware
package whose platform-contract identities match. It stages immutable copies,
renders and checks the strict BIF, invokes `bootgen -arch versal`, and emits a
PDI plus composition hashes and a deployment identity. Callers cannot inject an
extra core, partition, handoff policy, or path.

The hardware package must provide `coyoteR5Platform` with API
`coyote-nix.v80-r5-platform/v1`, a base PDI, canonical platform metadata,
platform identity, source-contract identity, exact Xilinx version, and the
fixed subsystem ID. Composition rechecks the base-PDI hash, firmware metadata
and identity, complete platform contract, and ELF policy before Bootgen. Until
the implemented Coyote base PDI exists, the
BIF and firmware can be built and checked independently, while synthetic
Bootgen package tests validate the composition machinery.
