#!/usr/bin/env python3
"""Retain existing Coyote stage outputs and check their physical inventory."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

STAGE_TOOL = Path(__file__).with_name("coyote-implementation-stage.py")
INVENTORY_API = "coyote-nix.physical-retention/v1"


def stage_module():
    spec = importlib.util.spec_from_file_location("coyote_stage_manifest", STAGE_TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def valid_store_path(value):
    if not isinstance(value, str):
        raise ValueError(f"not an existing stage output store path: {value!r}")
    path = Path(value)
    if (
        not path.is_absolute()
        or path.parent != Path("/nix/store")
        or not re.fullmatch(r"[0-9a-z]{32}-.+", path.name)
        or path.name.endswith(".drv")
    ):
        raise ValueError(f"not an existing stage output store path: {value}")
    return str(path)


def store_path_valid(path):
    result = subprocess.run(
        ["nix-store", "--check-validity", path], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    return result.returncode == 0


def stage_record(raw_path):
    store_path = valid_store_path(raw_path)
    stage_dir = Path(store_path)
    manifest = stage_module().validate_manifest(stage_dir)
    artifacts = [a for a in manifest["artifacts"] if "checkpoint" in a["role"]]
    if not artifacts:
        raise ValueError(f"stage {store_path} declares no checkpoint artifact")
    artifact = artifacts[0]
    checkpoint = stage_module().resolve_contained(stage_dir, stage_module().safe_relative(artifact["path"]))
    if stage_module().sha256_file(checkpoint) != artifact["sha256"]:
        raise ValueError(f"checkpoint hash mismatch in {store_path}: {artifact['path']}")
    return {
        "storePath": store_path,
        "phase": manifest["phase"],
        "unit": manifest["unit"],
        "contextId": manifest["context"]["id"],
        "manifestId": manifest["manifestId"],
        "recipeId": manifest.get("recipeId"),
        "checkpoint": {"role": artifact["role"], "path": artifact["path"], "sha256": artifact["sha256"]},
    }


def root_name(store_path):
    return "coyote-physical-" + hashlib.sha256(store_path.encode()).hexdigest()[:20]


def read_inventory(path):
    try:
        inventory = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read inventory {path}: {error}") from error
    if not isinstance(inventory, dict) or inventory.get("api") != INVENTORY_API or not isinstance(inventory.get("stages"), list):
        raise ValueError("unsupported or malformed physical-retention inventory")
    stages = inventory["stages"]
    if not stages:
        raise ValueError("physical-retention inventory contains no stages")
    required = {"storePath", "phase", "unit", "contextId", "manifestId", "recipeId", "checkpoint"}
    checkpoint_fields = {"role", "path", "sha256"}
    seen_paths = set()
    for index, stage in enumerate(stages):
        if not isinstance(stage, dict) or set(stage) != required:
            raise ValueError(f"malformed stage entry at index {index}")
        store_path = valid_store_path(stage["storePath"])
        if store_path in seen_paths:
            raise ValueError(f"duplicate stage store path in inventory: {store_path}")
        seen_paths.add(store_path)
        for field in ("phase", "unit"):
            if not isinstance(stage[field], str) or not stage[field]:
                raise ValueError(f"malformed stage {field} at index {index}")
        for field in ("contextId", "manifestId"):
            if not isinstance(stage[field], str) or re.fullmatch(r"[0-9a-f]{64}", stage[field]) is None:
                raise ValueError(f"malformed stage {field} at index {index}")
        recipe_id = stage["recipeId"]
        if recipe_id is not None and (not isinstance(recipe_id, str) or re.fullmatch(r"[0-9a-f]{64}", recipe_id) is None):
            raise ValueError(f"malformed stage recipeId at index {index}")
        checkpoint = stage["checkpoint"]
        if not isinstance(checkpoint, dict) or set(checkpoint) != checkpoint_fields:
            raise ValueError(f"malformed checkpoint identity at stage index {index}")
        if not isinstance(checkpoint["role"], str) or "checkpoint" not in checkpoint["role"]:
            raise ValueError(f"malformed checkpoint role at stage index {index}")
        if not isinstance(checkpoint["path"], str):
            raise ValueError(f"malformed checkpoint path at stage index {index}")
        stage_module().safe_relative(checkpoint["path"])
        if not isinstance(checkpoint["sha256"], str) or re.fullmatch(r"[0-9a-f]{64}", checkpoint["sha256"]) is None:
            raise ValueError(f"malformed checkpoint sha256 at stage index {index}")
    return inventory


def registered_roots(store_path):
    result = subprocess.run(
        ["nix-store", "--query", "--roots", store_path], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        raise ValueError(f"cannot query registered Nix GC roots for {store_path}: {result.stderr.strip()}")
    roots = set()
    for line in result.stdout.splitlines():
        root, separator, target = line.rpartition(" -> ")
        if separator and target.strip() == store_path:
            roots.add(os.path.abspath(root.strip()))
    return roots


def check(inventory_path, roots_dir):
    inventory = read_inventory(inventory_path)
    issues = 0
    for stage in inventory["stages"]:
        store_path = valid_store_path(stage.get("storePath", ""))
        link = roots_dir / root_name(store_path)
        if link.is_symlink() and not link.exists():
            print(f"DANGLING GC ROOT: {store_path} ({link})")
            issues += 1
        if not link.is_symlink():
            reason = "MISSING GC ROOT" if not link.exists() else "WRONG GC ROOT"
            print(f"{reason}: {store_path} ({link})")
            issues += 1
        else:
            target_matches = os.path.realpath(link) == store_path
            if not target_matches:
                print(f"WRONG GC ROOT: {store_path} ({link})")
                issues += 1
        if not store_path_valid(store_path):
            print(f"MISSING STORE PATH: {store_path}")
            issues += 1
            continue
        if link.is_symlink() and os.path.realpath(link) == store_path:
            if str(link.absolute()) not in registered_roots(store_path):
                print(f"UNREGISTERED GC ROOT: {store_path} ({link})")
                issues += 1
        try:
            current = stage_record(store_path)
        except Exception as error:
            print(f"HASH/manifest mismatch: {store_path}: {error}")
            issues += 1
            continue
        if current != stage:
            print(f"HASH/manifest/inventory mismatch: {store_path}")
            issues += 1
        else:
            expected = stage["checkpoint"]
            print(f"OK: {store_path} (manifest {stage['manifestId']}, checkpoint sha256 {expected['sha256']})")
    print(f"Check complete: {issues} issue(s); missing paths can be recovered explicitly with nix copy.")
    return 1 if issues else 0


def retain(stage_paths, inventory_path, roots_dir):
    if inventory_path.exists() or inventory_path.is_symlink():
        raise ValueError(f"refusing to overwrite existing inventory: {inventory_path}")
    stages = [stage_record(path) for path in stage_paths]
    paths = [stage["storePath"] for stage in stages]
    if len(set(paths)) != len(paths):
        raise ValueError("duplicate stage store path")
    for path in paths:
        if not store_path_valid(path):
            raise ValueError(f"store path is not already valid; refusing to build or download: {path}")
    inventory_path.parent.mkdir(parents=True, exist_ok=True)
    roots_dir.mkdir(parents=True, exist_ok=True)
    roots_dir = Path(os.path.abspath(roots_dir))
    links = [(roots_dir / root_name(path), path) for path in paths]
    for link, _ in links:
        if link.exists() or link.is_symlink():
            raise ValueError(f"refusing to overwrite existing GC root: {link}")
    created = []
    try:
        for link, target in links:
            result = subprocess.run(
                [
                    "nix-store", "--option", "substitute", "false", "--add-root",
                    str(link), "--indirect", "--realise", target,
                ],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )
            if result.returncode:
                raise ValueError(f"nix-store could not register GC root for {target}: {result.stderr.strip()}")
            created.append(link)
            if not link.is_symlink() or os.path.realpath(link) != target:
                raise ValueError(f"Nix GC root was not created as expected: {link}")
            if str(link) not in registered_roots(target):
                raise ValueError(f"Nix did not report the new GC root as registered: {link}")
        document = {"api": INVENTORY_API, "stages": stages}
        inventory_path.parent.mkdir(parents=True, exist_ok=True)
        with inventory_path.open("x", encoding="utf-8") as stream:
            json.dump(document, stream, sort_keys=True, indent=2)
            stream.write("\n")
    except Exception:
        for link in created:
            link.unlink(missing_ok=True)
        raise
    print(f"Retained {len(stages)} existing stage output(s) in {inventory_path}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check an inventory without modifying roots")
    parser.add_argument("--roots", type=Path, help="GC-root link directory (default: INVENTORY.roots)")
    parser.add_argument("inventory", type=Path)
    parser.add_argument("stage", nargs="*", help="existing stage store paths (retain mode)")
    args = parser.parse_args(argv)
    try:
        roots_dir = args.roots or args.inventory.with_name(args.inventory.name + ".roots")
        if args.check:
            if args.stage:
                parser.error("--check does not accept stage paths")
            return check(args.inventory, roots_dir)
        if not args.stage:
            parser.error("retain mode requires at least one stage store path")
        return retain(args.stage, args.inventory, roots_dir)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"coyote-retain-physical: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
