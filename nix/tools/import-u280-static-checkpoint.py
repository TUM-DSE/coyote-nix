#!/usr/bin/env python3
"""Validate and normalize an immutable U280 shell checkpoint for static reuse."""

import argparse
import hashlib
import importlib.util
import json
import re
import shutil
import sys
from pathlib import Path

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
REQUIRED_ROLES = {
    "validated-checkpoint",
    "validate-timing-summary-report",
    "validate-route-status-report",
    "bitstream-drc-report",
    "validation-result",
    "physical-observations",
}


def fail(message: str) -> None:
    raise ValueError(message)


def load_stage_module():
    path = Path(__file__).with_name("coyote-implementation-stage.py")
    spec = importlib.util.spec_from_file_location("coyote_implementation_stage", path)
    if spec is None or spec.loader is None:
        fail(f"cannot load implementation-stage validator: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_json(path: Path):
    try:
        with path.open("r", encoding="utf-8") as stream:
            return json.load(stream)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read JSON {path}: {error}")


def artifact_by_role(stage: Path, manifest: dict, role: str) -> tuple[dict, Path]:
    entries = [entry for entry in manifest["artifacts"] if entry["role"] == role]
    if len(entries) != 1:
        fail(f"validated stage must declare exactly one {role} artifact")
    entry = entries[0]
    path = stage / entry["path"]
    return entry, path


def require_number(value, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail(f"physical observations require numeric {label}")
    return float(value)


def route_count(report: str, label: str) -> int:
    match = re.search(rf"# of {re.escape(label)}\.*\s*:\s*([0-9]+)\s*:", report)
    if match is None:
        fail(f"route-status report does not declare {label}")
    return int(match.group(1))


def validate(args: argparse.Namespace) -> dict:
    if not SHA256_RE.fullmatch(args.manifest_id):
        fail("expected manifest ID must be a lowercase SHA-256 digest")
    if not SHA256_RE.fullmatch(args.checkpoint_sha256):
        fail("expected checkpoint hash must be a lowercase SHA-256 digest")
    if not SHA256_RE.fullmatch(args.coyote_source_id):
        fail("expected Coyote source ID must be a lowercase SHA-256 digest")
    if args.fixed_route_nets < 1:
        fail("expected fixed-route net count must be positive")
    if args.reconfigurable_cell != "inst_shell":
        fail("U280 static reuse supports only the canonical inst_shell replacement cell")

    implementation_stage = load_stage_module()
    manifest = implementation_stage.validate_manifest(args.stage, expected_phase="validate")
    context = manifest["context"]
    expected_context = {
        "board": args.board,
        "architecture": args.architecture,
        "part": args.part,
        "flow": "build-shell",
        "coyoteSourceId": args.coyote_source_id,
        "toolVersion": args.tool_version,
        "topology": {"configurations": 1, "regions": 1},
    }
    if manifest.get("manifestId") != args.manifest_id:
        fail("validated-stage manifest ID does not match the pinned contract")
    if manifest.get("unit") != "shell" or manifest.get("outcome") != "accepted":
        fail("static reuse requires an accepted shell validation stage")
    for key, expected in expected_context.items():
        if context.get(key) != expected:
            fail(f"incompatible validated-stage context field {key}: expected {expected!r}, got {context.get(key)!r}")

    roles = {entry["role"] for entry in manifest["artifacts"]}
    missing = sorted(REQUIRED_ROLES - roles)
    if missing:
        fail(f"validated stage lacks required hashed evidence roles: {', '.join(missing)}")

    checkpoint_entry, checkpoint = artifact_by_role(args.stage, manifest, "validated-checkpoint")
    if checkpoint_entry["sha256"] != args.checkpoint_sha256:
        fail("validated checkpoint hash does not match the pinned contract")

    validation_entry, validation_path = artifact_by_role(args.stage, manifest, "validation-result")
    validation = load_json(validation_path)
    if validation.get("outcome") != "accepted" or validation.get("reasons") != []:
        fail("validation report is not an unconditional acceptance")

    physical_entry, physical_path = artifact_by_role(args.stage, manifest, "physical-observations")
    physical = load_json(physical_path)
    if (
        physical.get("schemaVersion") != 1
        or physical.get("kind") != "coyote-implementation-observations"
        or physical.get("phase") != "validate"
        or physical.get("analysisKind") != "routed"
        or physical.get("vivadoVersion") != args.tool_version
    ):
        fail("physical observations are incompatible with routed U280 validation")
    timing = physical.get("timing", {})
    if (
        require_number(timing.get("setupWnsNs"), "setup WNS") < 0
        or require_number(timing.get("setupTnsNs"), "setup TNS") != 0
        or require_number(timing.get("holdWnsNs"), "hold WNS") < 0
        or require_number(timing.get("holdTnsNs"), "hold TNS") != 0
    ):
        fail("source checkpoint is not setup- and hold-clean")
    routing = physical.get("routing", {})
    if any(routing.get(key) != 0 for key in ("unroutedNets", "partiallyRoutedNets", "conflictedNets", "hasRoutingErrors")):
        fail("source checkpoint does not have clean routing")
    drc = physical.get("drc", {})
    if drc.get("errors") != 0 or drc.get("criticalWarnings") != 0:
        fail("source checkpoint does not have clean bitstream DRC")

    route_entry, route_path = artifact_by_role(args.stage, manifest, "validate-route-status-report")
    try:
        route_report = route_path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read route-status report: {error}")
    fixed_routes = route_count(route_report, "nets with fixed routing")
    routable = route_count(route_report, "routable nets")
    fully_routed = route_count(route_report, "fully routed nets")
    route_errors = route_count(route_report, "nets with routing errors")
    if fixed_routes != args.fixed_route_nets:
        fail(f"fixed-route lock count changed: expected {args.fixed_route_nets}, got {fixed_routes}")
    if routable < 1 or fully_routed != routable or route_errors != 0:
        fail("route-status report is not fully routed and error-free")

    report_roles = sorted(REQUIRED_ROLES - {"validated-checkpoint"})
    reports = {}
    for role in report_roles:
        entry, path = artifact_by_role(args.stage, manifest, role)
        reports[role] = {
            "sourcePath": entry["path"],
            "sha256": entry["sha256"],
            "size": entry["size"],
        }
        destination = args.output / "reports" / path.name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)

    output_checkpoint = args.output / "checkpoints" / "static_routed_locked_u280.dcp"
    output_checkpoint.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(checkpoint, output_checkpoint)
    if implementation_stage.sha256_file(output_checkpoint) != args.checkpoint_sha256:
        fail("normalized checkpoint hash changed while copying")

    metadata = {
        "schemaVersion": 1,
        "api": "coyote-nix.u280-static-checkpoint/v1",
        "kind": "coyote-u280-imported-static-checkpoint",
        "source": {
            "stage": str(args.stage),
            "manifestId": args.manifest_id,
            "checkpointPath": checkpoint_entry["path"],
            "checkpointSha256": args.checkpoint_sha256,
        },
        "compatibility": expected_context,
        "protectedStatic": {
            "scope": f"outside:{args.reconfigurable_cell}",
            "lockLevel": "routing",
            "fixedRouteNets": fixed_routes,
            "placementFromValidatedCheckpoint": True,
            "routingFixed": True,
        },
        "applicationLink": {
            "reconfigurableCell": args.reconfigurable_cell,
            "partitionPins": "preserve-from-validated-checkpoint",
            "protectedStatic": "reject-drift",
        },
        "reports": reports,
    }
    metadata_directory = args.output / "metadata"
    metadata_directory.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.stage / "metadata" / "stage.json", metadata_directory / "source-stage.json")
    with (metadata_directory / "static-checkpoint.json").open("w", encoding="utf-8") as stream:
        json.dump(metadata, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--manifest-id", required=True)
    parser.add_argument("--checkpoint-sha256", required=True)
    parser.add_argument("--coyote-source-id", required=True)
    parser.add_argument("--fixed-route-nets", required=True, type=int)
    parser.add_argument("--board", default="u280")
    parser.add_argument("--architecture", default="ultrascale_plus")
    parser.add_argument("--part", default="xcu280-fsvh2892-2L-e")
    parser.add_argument("--tool-version", required=True)
    parser.add_argument("--reconfigurable-cell", default="inst_shell")
    args = parser.parse_args()
    try:
        validate(args)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
