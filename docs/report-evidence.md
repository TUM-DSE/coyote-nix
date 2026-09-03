# Matched implementation-report evidence

`coyote-report-evidence` is a device-free extractor for comparing a standalone-Coyote implementation with a QShell implementation. It reads immutable, hash-addressed package reports, rejects unmatched or non-signoff inputs, and emits one canonical JSON record containing timing, latency-boundary, utilization, provenance, and overhead evidence.

The tool does not run Vivado, build an FPGA image, or access hardware. It only accepts measurements that already exist.

## Flake outputs

```sh
# Build the packaged extractor and schema.
nix build .#coyote-report-evidence

# Run the app.
nix run .#coyote-report-evidence -- compare request.json --output evidence.json

# Run the report/parser/matching/schema contract.
nix build .#checks.x86_64-linux.matched-report-evidence
```

The package installs:

```text
bin/coyote-report-evidence
share/coyote-nix/schemas/matched-implementation-evidence-v1.schema.json
share/doc/coyote-report-evidence/report-evidence.md
```

The source schema is [`schemas/matched-implementation-evidence-v1.schema.json`](../schemas/matched-implementation-evidence-v1.schema.json). It uses JSON Schema draft 2020-12, fixes the output API to `coyote-nix.matched-implementation-evidence/v1`, and rejects unknown properties at every object boundary. The extractor also enforces cross-file hashes, identities, ordering, and equality constraints that JSON Schema cannot express.

## Request and package provenance

A request names two absolute package roots and the hash of each provenance manifest:

```json
{
  "schemaVersion": 1,
  "api": "coyote-nix.matched-implementation-request/v1",
  "baseline": {
    "packageRoot": "/nix/store/...-standalone-coyote",
    "provenance": {
      "path": "metadata/implementation-report-provenance.json",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  },
  "qshell": {
    "packageRoot": "/nix/store/...-qshell",
    "provenance": {
      "path": "metadata/implementation-report-provenance.json",
      "sha256": "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    }
  }
}
```

Paths must be canonical, relative to their package root, and remain inside that root after symlink resolution. Duplicate JSON keys, non-finite values, missing files, and hash changes fail closed.

Each provenance file has this exact shape:

```json
{
  "schemaVersion": 1,
  "api": "coyote-nix.implementation-report-provenance/v1",
  "deployment": "standalone-coyote",
  "packageName": "microblossom-circuit-d9-u280",
  "definition": {
    "board": {
      "name": "u280",
      "part": "xcu280-fsvh2892-2L-e"
    },
    "distance": 9,
    "decoder": {
      "family": "microblossom",
      "variant": "circuit-level-surface-code",
      "rtlSha256": "...64 lowercase hexadecimal digits...",
      "graphSha256": "...64 lowercase hexadecimal digits..."
    },
    "clock": {
      "definitionId": "...64 lowercase hexadecimal digits...",
      "shellHz": 250000000,
      "decoderHz": 125000000
    },
    "peer": {
      "definitionId": "...64 lowercase hexadecimal digits...",
      "mode": "aurora-64b66b-whole-vector",
      "included": true
    }
  },
  "build": {
    "strategyId": "...64 lowercase hexadecimal digits...",
    "tool": {
      "name": "vivado",
      "version": "2023.2"
    },
    "outcome": "accepted"
  },
  "sources": [
    {
      "role": "decoder",
      "repository": "https://example.invalid/decoder.git",
      "revision": "...full 40- or 64-digit Git object ID...",
      "sourceSha256": "...64 lowercase hexadecimal digits..."
    },
    {
      "role": "coyote",
      "repository": "https://github.com/taugoust/Coyote.git",
      "revision": "...full Git object ID...",
      "sourceSha256": "...64 lowercase hexadecimal digits..."
    },
    {
      "role": "coyote-nix",
      "repository": "https://github.com/TUM-DSE/coyote-nix.git",
      "revision": "...full Git object ID...",
      "sourceSha256": "...64 lowercase hexadecimal digits..."
    }
  ],
  "reports": {
    "timing": {
      "path": "reports/shell_timing_summary.rpt",
      "sha256": "...64 lowercase hexadecimal digits..."
    },
    "latency": {
      "path": "reports/latency-boundaries.json",
      "sha256": "...64 lowercase hexadecimal digits..."
    },
    "utilization": {
      "path": "reports/shell_utilization.rpt",
      "sha256": "...64 lowercase hexadecimal digits..."
    }
  }
}
```

The QShell manifest uses `"deployment": "qshell"` and must add a unique `qshell` source role. Both deployments require `decoder`, `coyote`, and `coyote-nix` roles. `sourceSha256` is the producer's immutable source-closure identity; it is not inferred from a mutable checkout by this consumer.

## Accepted report inputs

Timing and utilization inputs are ordinary text reports from `report_timing_summary` and `report_utilization`. The extractor supports the current Vivado 2023.2 U280 and Vivado 2025.1 V80 table labels. It verifies:

- exactly one tool-version and device header in each report;
- the provenance tool version and FPGA part against both reports;
- one unambiguous design timing summary;
- internally consistent WNS/TNS and failing-endpoint counts;
- LUT, register, BRAM-tile, URAM, and DSP totals and capacities; and
- matching capacities before utilization overhead is calculated.

Only accepted, routed implementations with nonnegative setup and hold WNS, zero TNS, and zero failing endpoints can be compared. A routed report remains evidence rather than a substitute for the package producer's normal DRC, route, and validation gates; the provenance outcome must independently be `accepted`.

Representative report excerpts and latency samples for both board families are under [`tests/fixtures/report-evidence`](../tests/fixtures/report-evidence).

## Latency boundary contract

The latency report is strict JSON:

```json
{
  "schemaVersion": 1,
  "api": "coyote-nix.latency-boundary-samples/v1",
  "boundaryDefinition": "last-input-handshake-to-complete-correction-presentation/v1",
  "traceId": "...64 lowercase hexadecimal digits...",
  "unit": "fs",
  "samples": [
    {
      "sampleId": "trace-sample-0000",
      "requestSha256": "...64 lowercase hexadecimal digits...",
      "boundariesFs": {
        "inputComplete": 1000000000,
        "peerComplete": 1010000000,
        "dispatchComplete": 1018000000,
        "queueComplete": 1022000000,
        "decoderComplete": 1122000000,
        "outputComplete": 1130000000
      }
    }
  ]
}
```

All timestamps are nonnegative femtoseconds and must be monotonic within a sample. The boundaries are:

1. `inputComplete`: handshake of the final request beat at the measured input boundary;
2. `peerComplete`: complete request delivery across the selected peer boundary;
3. `dispatchComplete`: complete-record route acceptance;
4. `queueComplete`: complete-record release by the scheduler to the decoder;
5. `decoderComplete`: complete native correction availability;
6. `outputComplete`: complete validated correction presentation at the measured output boundary.

A deployment without a component records equal adjacent timestamps. For example, a host-local/no-peer path sets `peerComplete` equal to `inputComplete`, and a fixed standalone path can set dispatch and queue durations to zero. Producers must not estimate or synthesize a missing timestamp.

A comparison requires the same boundary definition, trace identity, ordered sample IDs, and request hashes. This gives every baseline and QShell sample a unique pair; aggregate-only or differently sampled measurements are rejected.

## Exact matching and output metrics

Overhead is emitted only when these complete definitions compare equal:

- board name and exact part;
- code distance;
- decoder family, variant, generated RTL hash, and graph hash;
- clock-definition identity plus shell and decoder frequencies; and
- peer-definition identity, mode, and inclusion state.

The implementation strategy and Vivado version must also match. This prevents a board, graph, clock, peer, tool, route strategy, or workload change from being mislabeled as QShell overhead.

Latency summaries use integer femtoseconds and nearest-rank p50/p99. `overhead.latency` contains baseline, QShell, and paired `QShell - baseline` statistics for the total and every component. Relative and component shares are rounded to the nearest integer part per million, with exact half cases rounded away from zero.

Utilization uses integer counts except BRAM, which uses milli-tiles so half-tile observations remain exact. Each resource reports absolute `QShell - baseline`, device-capacity parts per million (the percentage-point overhead), and relative parts per million. Relative overhead is explicitly unavailable when baseline use is zero.

`recordId` and `comparisonId` are SHA-256 identities over canonical JSON (UTF-8, sorted keys, compact separators, one trailing newline) before the corresponding ID field is inserted. The output also retains the hash and byte size of every consumed manifest and report.
