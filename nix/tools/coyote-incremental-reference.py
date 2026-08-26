#!/usr/bin/env python3
"""Validate and record an explicit U280 incremental implementation reference."""

import argparse
import importlib.util
from pathlib import Path
import sys


def load_stage_module(path: Path):
    spec = importlib.util.spec_from_file_location("coyote_implementation_stage", path)
    if spec is None or spec.loader is None:
        raise ValueError(f"cannot load implementation-stage validator: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_evidence(stage_tool: Path, stage_dir: Path, context_path: Path, output_path: Path) -> None:
    tool = load_stage_module(stage_tool)
    reference = tool.validate_manifest(stage_dir, expected_phase="validate")
    current_context = tool.load_json(context_path)
    if not isinstance(current_context, dict):
        tool.fail("incremental current context must be an object")
    if current_context.get("board") != "u280" or current_context.get("architecture") != "ultrascale_plus":
        tool.fail("incremental references support only the U280 UltraScale+ context")
    if reference.get("outcome") != "accepted":
        tool.fail("incremental reference validation outcome must be accepted")
    if reference.get("unit") != "config_0":
        tool.fail("incremental reference must describe config_0")

    reference_context = reference["context"]
    compatibility_fields = ("board", "architecture", "part", "flow", "topology", "toolId", "toolVersion")
    for field in compatibility_fields:
        if reference_context.get(field) != current_context.get(field):
            tool.fail(f"incremental reference context mismatch: {field}")

    checkpoints = [artifact for artifact in reference["artifacts"] if artifact["role"] == "validated-checkpoint"]
    if len(checkpoints) != 1:
        tool.fail("incremental reference requires exactly one validated-checkpoint artifact")
    checkpoint = checkpoints[0]
    evidence = {
        "schemaVersion": 1,
        "api": "coyote-nix.incremental-reference/v1",
        "selection": "explicit",
        "mode": "vivado-read-checkpoint-incremental",
        "reference": {
            "manifestId": reference["manifestId"],
            "recipeId": reference.get("recipeId", reference["manifestId"]),
            "contextId": reference_context["id"],
            "outcome": reference["outcome"],
            "checkpoint": {
                "role": checkpoint["role"],
                "path": checkpoint["path"],
                "sha256": checkpoint["sha256"],
                "size": checkpoint["size"],
            },
        },
        "currentContextId": current_context.get("id"),
        "compatibility": {field: current_context.get(field) for field in compatibility_fields},
        "signoffAuthority": False,
    }
    tool.atomic_write(output_path, tool.canonical(evidence))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("stage_tool", type=Path)
    parser.add_argument("stage_dir", type=Path)
    parser.add_argument("current_context", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        write_evidence(args.stage_tool, args.stage_dir, args.current_context, args.output)
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
