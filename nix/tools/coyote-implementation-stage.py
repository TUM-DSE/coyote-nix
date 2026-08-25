#!/usr/bin/env python3
"""Write, validate, and import immutable Coyote implementation-stage artifacts."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tempfile

API = "coyote-nix.implementation-stage/v1"
PHASES = ("inputs", "link", "opt", "place", "route", "validate", "finalize", "image")
TRANSITIONS = {
    "inputs": {None},
    "link": {"inputs"},
    "opt": {"link"},
    "place": {"opt"},
    "route": {"place"},
    "validate": {"route"},
    "finalize": {"validate"},
    "image": {"validate", "finalize"},
}


def fail(message: str) -> None:
    raise ValueError(message)


def load_json(path: Path):
    try:
        with path.open("r", encoding="utf-8") as stream:
            return json.load(stream)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read JSON {path}: {error}")


def canonical(value) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_relative(raw: str) -> PurePosixPath:
    if not isinstance(raw, str) or not raw:
        fail("artifact path must be a non-empty string")
    path = PurePosixPath(raw)
    if path.is_absolute() or ".." in path.parts or "." in path.parts or str(path) != raw:
        fail(f"unsafe or non-canonical artifact path: {raw}")
    return path


def resolve_contained(root: Path, relative: PurePosixPath) -> Path:
    root_real = root.resolve(strict=True)
    candidate = root.joinpath(*relative.parts)
    try:
        candidate_real = candidate.resolve(strict=True)
    except OSError as error:
        fail(f"missing artifact {relative}: {error}")
    try:
        candidate_real.relative_to(root_real)
    except ValueError:
        fail(f"artifact escapes stage root: {relative}")
    if not candidate_real.is_file():
        fail(f"artifact is not a regular file: {relative}")
    return candidate_real


def validate_manifest(stage_dir: Path, expected_phase=None, expected_context=None):
    manifest_path = stage_dir / "metadata" / "stage.json"
    complete_path = stage_dir / "metadata" / "complete"
    manifest = load_json(manifest_path)
    if manifest.get("api") != API or manifest.get("schemaVersion") != 1:
        fail("unsupported implementation-stage manifest API")
    phase = manifest.get("phase")
    if phase not in PHASES:
        fail(f"invalid phase: {phase}")
    if expected_phase is not None and phase != expected_phase:
        fail(f"expected phase {expected_phase}, got {phase}")
    context = manifest.get("context")
    required_context = ("id", "board", "architecture", "part", "flow", "sourceId", "constraintsId", "toolId")
    if not isinstance(context, dict) or not all(
        isinstance(context.get(key), str) and context[key] for key in required_context
    ):
        fail("manifest context requires non-empty id, board, architecture, part, flow, sourceId, constraintsId, and toolId")
    context_without_id = dict(context)
    context_id = context_without_id.pop("id")
    expected_context_id = hashlib.sha256(canonical(context_without_id).rstrip(b"\n")).hexdigest()
    if context_id != expected_context_id:
        fail("context ID does not match canonical context")
    if expected_context is not None and context["id"] != expected_context:
        fail(f"expected context {expected_context}, got {context['id']}")
    unit = manifest.get("unit")
    if not isinstance(unit, str) or not unit:
        fail("manifest unit is required")
    outcome = manifest.get("outcome")
    if outcome not in ("complete", "accepted", "rejected", "tool-failure"):
        fail("invalid stage outcome")
    predecessor = manifest.get("predecessor")
    predecessor_phase = None if predecessor is None else predecessor.get("phase")
    if predecessor_phase not in TRANSITIONS[phase]:
        fail(f"illegal phase transition {predecessor_phase} -> {phase}")
    if phase != "inputs":
        if not isinstance(predecessor, dict) or not all(
            isinstance(predecessor.get(key), str) and predecessor[key]
            for key in ("manifestId", "phase", "contextId", "unit", "outcome")
        ):
            fail("non-input stage requires complete predecessor identity")
        if predecessor["contextId"] != context["id"]:
            fail("predecessor context does not match stage context")
        if predecessor["unit"] != unit:
            fail("predecessor implementation unit does not match stage unit")
        if predecessor["outcome"] not in ("complete", "accepted"):
            fail("predecessor outcome is not consumable")
        if phase in ("finalize", "image") and predecessor["outcome"] != "accepted":
            fail("image stage requires an accepted validation predecessor")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        fail("manifest must declare at least one artifact")
    roles = set()
    paths = set()
    artifacts_by_role = {}
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            fail("artifact entry must be an object")
        role = artifact.get("role")
        if not isinstance(role, str) or not role or role in roles:
            fail(f"invalid or duplicate artifact role: {role}")
        roles.add(role)
        artifacts_by_role[role] = artifact
        relative = safe_relative(artifact.get("path"))
        if str(relative) in paths:
            fail(f"duplicate artifact path: {relative}")
        paths.add(str(relative))
        actual = resolve_contained(stage_dir, relative)
        if artifact.get("sha256") != sha256_file(actual):
            fail(f"artifact hash mismatch: {relative}")
        if artifact.get("size") != actual.stat().st_size:
            fail(f"artifact size mismatch: {relative}")
    if phase == "validate":
        if "validated-checkpoint" not in artifacts_by_role or "validation-result" not in artifacts_by_role:
            fail("validate stage requires validated-checkpoint and validation-result artifacts")
        result_path = safe_relative(artifacts_by_role["validation-result"]["path"])
        result = load_json(resolve_contained(stage_dir, result_path))
        if result.get("outcome") not in ("accepted", "rejected"):
            fail("validation result has invalid outcome")
        if result["outcome"] != outcome:
            fail("validation result outcome does not match manifest")
    manifest_without_id = dict(manifest)
    manifest_id = manifest_without_id.pop("manifestId", None)
    expected_id = hashlib.sha256(canonical(manifest_without_id)).hexdigest()
    if manifest_id != expected_id:
        fail("manifest ID mismatch")
    try:
        complete_id = complete_path.read_text(encoding="utf-8").strip()
    except OSError as error:
        fail(f"missing completion identity: {error}")
    if complete_id != manifest_id:
        fail("completion identity does not match manifest")
    return manifest


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_manifest(spec_path: Path, artifact_root: Path, output_dir: Path) -> None:
    spec = load_json(spec_path)
    if not isinstance(spec, dict):
        fail("stage specification must be an object")
    phase = spec.get("phase")
    if phase not in PHASES:
        fail(f"invalid phase: {phase}")
    context = spec.get("context")
    required_context = ("id", "board", "architecture", "part", "flow", "sourceId", "constraintsId", "toolId")
    if not isinstance(context, dict) or not all(
        isinstance(context.get(key), str) and context[key] for key in required_context
    ):
        fail("stage specification context requires non-empty id, board, architecture, part, flow, sourceId, constraintsId, and toolId")
    predecessor_path = spec.pop("predecessorPath", None)
    outcome_path = spec.pop("outcomePath", None)
    predecessor = None
    if phase != "inputs":
        if not isinstance(predecessor_path, str) or not predecessor_path:
            fail("non-input stage requires predecessorPath")
        previous = validate_manifest(Path(predecessor_path), expected_context=context["id"])
        if previous["phase"] not in TRANSITIONS[phase]:
            fail(f"illegal phase transition {previous['phase']} -> {phase}")
        predecessor = {
            "manifestId": previous["manifestId"],
            "phase": previous["phase"],
            "contextId": previous["context"]["id"],
            "unit": previous["unit"],
            "outcome": previous["outcome"],
        }
    elif predecessor_path is not None:
        fail("inputs stage must not have a predecessor")
    declarations = spec.get("artifacts")
    if not isinstance(declarations, list) or not declarations:
        fail("stage specification must declare artifacts")
    artifacts = []
    for declaration in declarations:
        if not isinstance(declaration, dict) or set(declaration) != {"role", "path"}:
            fail("artifact declaration must contain exactly role and path")
        relative = safe_relative(declaration["path"])
        source = resolve_contained(artifact_root, relative)
        artifacts.append({
            "role": declaration["role"],
            "path": str(relative),
            "sha256": sha256_file(source),
            "size": source.stat().st_size,
        })
    outcome = spec.get("outcome", "complete")
    if outcome_path is not None:
        relative_outcome = safe_relative(outcome_path)
        outcome_document = load_json(resolve_contained(artifact_root, relative_outcome))
        outcome = outcome_document.get("outcome")
    manifest = {
        "schemaVersion": 1,
        "api": API,
        "phase": phase,
        "unit": spec.get("unit"),
        "context": context,
        "predecessor": predecessor,
        "strategy": spec.get("strategy", {}),
        "resources": spec.get("resources", {}),
        "outcome": outcome,
        "artifacts": artifacts,
    }
    if not isinstance(manifest["unit"], str) or not manifest["unit"]:
        fail("stage specification requires unit")
    if manifest["outcome"] not in ("complete", "accepted", "rejected", "tool-failure"):
        fail("invalid stage outcome")
    manifest_id = hashlib.sha256(canonical(manifest)).hexdigest()
    manifest["manifestId"] = manifest_id
    metadata = output_dir / "metadata"
    metadata.mkdir(parents=True, exist_ok=True)
    atomic_write(metadata / "stage.json", canonical(manifest))
    atomic_write(metadata / "complete", (manifest_id + "\n").encode())
    validate_manifest(output_dir)


def import_artifacts(stage_dir: Path, destination: Path, roles):
    manifest = validate_manifest(stage_dir)
    by_role = {artifact["role"]: artifact for artifact in manifest["artifacts"]}
    requested = roles or sorted(by_role)
    for role in requested:
        if role not in by_role:
            fail(f"predecessor does not declare artifact role: {role}")
        artifact = by_role[role]
        relative = safe_relative(artifact["path"])
        source = resolve_contained(stage_dir, relative)
        target = destination.joinpath(*relative.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        if sha256_file(target) != artifact["sha256"]:
            fail(f"imported artifact hash mismatch: {relative}")


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    write = subparsers.add_parser("write")
    write.add_argument("spec", type=Path)
    write.add_argument("artifact_root", type=Path)
    write.add_argument("output_dir", type=Path)
    validate = subparsers.add_parser("validate")
    validate.add_argument("stage_dir", type=Path)
    validate.add_argument("--phase")
    validate.add_argument("--context")
    copy = subparsers.add_parser("import")
    copy.add_argument("stage_dir", type=Path)
    copy.add_argument("destination", type=Path)
    copy.add_argument("roles", nargs="*")
    args = parser.parse_args()
    try:
        if args.command == "write":
            write_manifest(args.spec, args.artifact_root, args.output_dir)
        elif args.command == "validate":
            validate_manifest(args.stage_dir, args.phase, args.context)
        else:
            import_artifacts(args.stage_dir, args.destination, args.roles)
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
