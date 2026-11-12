#!/usr/bin/env python3
"""Import the routed U280 shell checkpoint of an earlier build as a static layer.

The checkpoint is pinned by its SHA-256, and its route-status report must show
the expected number of fixed (locked) nets and complete, error-free routing.
"""

import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CHECKPOINT = Path("checkpoints/shell_routed.dcp")
ROUTE_STATUS = Path("reports/shell_route_status.rpt")
VALIDATION = Path("reports/validation.json")


def fail(message: str) -> None:
    raise ValueError(message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def route_count(report: str, label: str) -> int:
    match = re.search(rf"# of {re.escape(label)}\.*\s*:\s*(\d+)", report)
    if match is None:
        fail(f"route-status report lacks '{label}'")
    return int(match.group(1))


def import_checkpoint(args: argparse.Namespace) -> None:
    if not SHA256_RE.fullmatch(args.checkpoint_sha256):
        fail("checkpoint SHA-256 must be a lowercase hexadecimal digest")
    if args.fixed_route_nets < 1:
        fail("expected fixed-route net count must be positive")

    checkpoint = args.stage / CHECKPOINT
    if not checkpoint.is_file():
        fail(f"source stage has no {CHECKPOINT}")
    if sha256_file(checkpoint) != args.checkpoint_sha256:
        fail("source checkpoint does not match the pinned SHA-256")

    report = (args.stage / ROUTE_STATUS).read_text(encoding="utf-8")
    fixed_routes = route_count(report, "nets with fixed routing")
    routable = route_count(report, "routable nets")
    fully_routed = route_count(report, "fully routed nets")
    route_errors = route_count(report, "nets with routing errors")
    if fixed_routes != args.fixed_route_nets:
        fail(f"fixed-route lock count changed: expected {args.fixed_route_nets}, got {fixed_routes}")
    if routable < 1 or fully_routed != routable or route_errors != 0:
        fail("source checkpoint is not fully routed without errors")

    validation_path = args.stage / VALIDATION
    if validation_path.is_file():
        validation = json.loads(validation_path.read_text(encoding="utf-8"))
        if validation.get("outcome") != "accepted":
            print("WARNING: the imported static checkpoint failed validation:", file=sys.stderr)
            for reason in validation.get("reasons", []):
                print(f"  - {reason}", file=sys.stderr)

    output_checkpoint = args.output / "checkpoints" / "static_routed_locked_u280.dcp"
    output_checkpoint.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(checkpoint, output_checkpoint)
    if (args.stage / "reports").is_dir():
        shutil.copytree(args.stage / "reports", args.output / "reports")

    metadata = {
        "schemaVersion": 1,
        "api": "coyote-nix.u280-static-checkpoint/v1",
        "kind": "coyote-u280-imported-static-checkpoint",
        "source": {
            "stage": str(args.stage),
            "checkpointPath": str(CHECKPOINT),
            "checkpointSha256": args.checkpoint_sha256,
        },
        "compatibility": {
            "board": args.board,
            "architecture": args.architecture,
            "part": args.part,
            "toolVersion": args.tool_version,
        },
        "protectedStatic": {
            "scope": f"outside:{args.reconfigurable_cell}",
            "lockLevel": "routing",
            "fixedRouteNets": fixed_routes,
        },
        "applicationLink": {
            "reconfigurableCell": args.reconfigurable_cell,
            "partitionPins": "preserve-from-source-checkpoint",
            "protectedStatic": "reject-drift",
        },
    }
    metadata_directory = args.output / "metadata"
    metadata_directory.mkdir(parents=True, exist_ok=True)
    with (metadata_directory / "static-checkpoint.json").open("w", encoding="utf-8") as stream:
        json.dump(metadata, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--checkpoint-sha256", required=True)
    parser.add_argument("--fixed-route-nets", required=True, type=int)
    parser.add_argument("--board", default="u280")
    parser.add_argument("--architecture", default="ultrascale_plus")
    parser.add_argument("--part", default="xcu280-fsvh2892-2L-e")
    parser.add_argument("--tool-version", required=True)
    parser.add_argument("--reconfigurable-cell", default="inst_shell")
    args = parser.parse_args()
    try:
        import_checkpoint(args)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
