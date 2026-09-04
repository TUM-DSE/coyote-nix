#!/usr/bin/env python3
"""Build and verify a narrowly scoped, immutable Coyote source delta."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
REVISION_RE = re.compile(r"^[0-9a-f]{40}$")
DIFF_HEADER_RE = re.compile(r"^diff --git a/([^\s]+) b/([^\s]+)$")
POLICIES = {
    "user-project-generation": {
        "schemaVersion": 1,
        "api": "coyote-nix.coyote-source-delta-policy/v1",
        "name": "user-project-generation",
        "allowedPrefixes": [
            "scripts/cr_prjcts/",
            "tests/user_project_source_management/",
        ],
        "allowAdditions": True,
        "allowDeletions": False,
        "allowModeChanges": False,
    }
}
REQUIRED_PROOF_ENTRIES = {"source", "metadata"}
REQUIRED_METADATA_ENTRIES = {"complete.json", "delta.json", "tree-manifest.json"}


class DeltaError(ValueError):
    """A fail-closed source-delta validation error."""


def fail(message: str) -> None:
    raise DeltaError(message)


def canonical(value: Any, newline: bool = False) -> bytes:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return encoded + (b"\n" if newline else b"")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_id(path: Path) -> str:
    return sha256_bytes(str(path).encode("utf-8"))


def validate_digest(value: str, label: str) -> None:
    if SHA256_RE.fullmatch(value) is None:
        fail(f"{label} must be a lowercase SHA-256 digest")


def validate_revision(value: str, label: str) -> None:
    if REVISION_RE.fullmatch(value) is None:
        fail(f"{label} must be a lowercase 40-character Git revision")


def validate_relative_path(value: str, label: str = "changed path") -> str:
    if not value or "\\" in value or "\x00" in value:
        fail(f"{label} is not a canonical POSIX path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or str(path) != value:
        fail(f"{label} is not a canonical relative path: {value!r}")
    if any(component in ("", ".", "..") for component in path.parts):
        fail(f"{label} contains an unsafe component: {value!r}")
    return value


def checked_paths(values: list[str]) -> list[str]:
    paths = [validate_relative_path(value) for value in values]
    if not paths:
        fail("the declared changed-path set must not be empty")
    if paths != sorted(set(paths)):
        fail("declared changed paths must be unique and bytewise sorted")
    return paths


def policy_contract(name: str) -> dict[str, Any]:
    try:
        return POLICIES[name]
    except KeyError:
        fail(f"unsupported source-delta policy: {name}")


def policy_id(name: str) -> str:
    return sha256_bytes(canonical(policy_contract(name)))


def delta_contract(args: argparse.Namespace, paths: list[str]) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "api": "coyote-nix.coyote-source-delta-contract/v1",
        "policyId": args.policy_id,
        "base": {
            "sourceId": args.base_source_id,
            "revision": args.base_revision,
        },
        "candidate": {
            "sourceId": args.candidate_source_id,
            "revision": args.candidate_revision,
        },
        "patch": {
            "sha256": args.patch_sha256,
            "changedPaths": paths,
        },
    }


def require_plain_directory(path: Path, label: str) -> None:
    try:
        info = path.lstat()
    except OSError as error:
        fail(f"cannot inspect {label} {path}: {error}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        fail(f"{label} must be a real directory: {path}")


def require_plain_file(path: Path, label: str) -> None:
    try:
        info = path.lstat()
    except OSError as error:
        fail(f"cannot inspect {label} {path}: {error}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail(f"{label} must be a real regular file: {path}")


def safe_symlink(root: Path, path: Path, target: str) -> None:
    if not target or os.path.isabs(target):
        fail(f"source tree contains an absolute or empty symlink: {path} -> {target!r}")
    try:
        resolved = (path.parent / target).resolve(strict=True)
        resolved.relative_to(root.resolve(strict=True))
    except (OSError, RuntimeError, ValueError) as error:
        fail(f"source tree contains a symlink escape or unresolved link: {path} -> {target!r}: {error}")


def tree_manifest(root: Path, label: str) -> list[dict[str, Any]]:
    require_plain_directory(root, label)
    entries: list[dict[str, Any]] = []

    def visit(directory: Path) -> None:
        try:
            children = sorted(os.scandir(directory), key=lambda item: os.fsencode(item.name))
        except OSError as error:
            fail(f"cannot enumerate {label} {directory}: {error}")
        for child in children:
            path = Path(child.path)
            relative = path.relative_to(root).as_posix()
            validate_relative_path(relative, f"{label} entry")
            try:
                info = child.stat(follow_symlinks=False)
            except OSError as error:
                fail(f"cannot inspect {label} entry {relative}: {error}")
            mode = f"{stat.S_IMODE(info.st_mode):04o}"
            if stat.S_ISDIR(info.st_mode):
                entries.append({"path": relative, "type": "directory", "mode": mode})
                visit(path)
            elif stat.S_ISREG(info.st_mode):
                entries.append(
                    {
                        "path": relative,
                        "type": "regular",
                        "mode": mode,
                        "size": info.st_size,
                        "sha256": sha256_file(path),
                    }
                )
            elif stat.S_ISLNK(info.st_mode):
                target = os.readlink(path)
                safe_symlink(root, path, target)
                entries.append(
                    {
                        "path": relative,
                        "type": "symlink",
                        "mode": mode,
                        "target": target,
                    }
                )
            else:
                fail(f"{label} contains a special file: {relative}")

    visit(root)
    return entries


def manifest_map(entries: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {entry["path"]: entry for entry in entries}


def changed_leaf_paths(
    base_entries: list[dict[str, Any]], candidate_entries: list[dict[str, Any]]
) -> list[str]:
    base = manifest_map(base_entries)
    candidate = manifest_map(candidate_entries)
    changed: list[str] = []
    for path in sorted(set(base) | set(candidate)):
        before = base.get(path)
        after = candidate.get(path)
        if before == after:
            continue
        # Git does not track directories. New parent directories are represented
        # by their changed leaves, while mutations to an existing directory are
        # never accepted silently.
        if before is None and after is not None and after["type"] == "directory":
            continue
        changed.append(path)
    return changed


def validate_policy_paths(paths: list[str], policy: dict[str, Any]) -> None:
    prefixes = policy["allowedPrefixes"]
    for path in paths:
        if not any(path.startswith(prefix) for prefix in prefixes):
            fail(f"changed path is outside policy {policy['name']}: {path}")


def validate_change_modes(
    paths: list[str],
    base_entries: list[dict[str, Any]],
    candidate_entries: list[dict[str, Any]],
    policy: dict[str, Any],
) -> list[dict[str, Any]]:
    base = manifest_map(base_entries)
    candidate = manifest_map(candidate_entries)
    changes: list[dict[str, Any]] = []
    for path in paths:
        before = base.get(path)
        after = candidate.get(path)
        if after is None:
            if not policy["allowDeletions"]:
                fail(f"source delta deletes a path: {path}")
        elif after["type"] != "regular":
            fail(f"changed source path is not a regular file: {path}")
        if before is None:
            if not policy["allowAdditions"]:
                fail(f"source delta adds a path: {path}")
            if after is not None and int(after["mode"], 8) & 0o111:
                fail(f"new source-delta file must not be executable: {path}")
        elif after is not None:
            if before["type"] != "regular":
                fail(f"changed base path is not a regular file: {path}")
            if not policy["allowModeChanges"] and before["mode"] != after["mode"]:
                fail(f"source delta changes file mode: {path}")
        changes.append(
            {
                "path": path,
                "before": None
                if before is None
                else {
                    "type": before["type"],
                    "mode": before["mode"],
                    "size": before.get("size"),
                    "sha256": before.get("sha256"),
                },
                "after": None
                if after is None
                else {
                    "type": after["type"],
                    "mode": after["mode"],
                    "size": after.get("size"),
                    "sha256": after.get("sha256"),
                },
            }
        )
    return changes


def parse_patch(path: Path, expected_paths: list[str]) -> None:
    require_plain_file(path, "source-delta patch")
    try:
        data = path.read_bytes()
    except OSError as error:
        fail(f"cannot read source-delta patch: {error}")
    if not data or b"\x00" in data:
        fail("source-delta patch is empty or contains NUL bytes")
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        fail(f"source-delta patch is not UTF-8 text: {error}")

    sections: list[tuple[str, list[str]]] = []
    current_path: str | None = None
    current_lines: list[str] = []
    for line in lines:
        match = DIFF_HEADER_RE.fullmatch(line)
        if match:
            if current_path is not None:
                sections.append((current_path, current_lines))
            old_path = validate_relative_path(match.group(1), "patch old path")
            new_path = validate_relative_path(match.group(2), "patch new path")
            if old_path != new_path:
                fail(f"source-delta patch renames or copies a path: {old_path} -> {new_path}")
            current_path = old_path
            current_lines = []
        elif current_path is None:
            if line.strip():
                fail("source-delta patch contains data before its first diff header")
        else:
            current_lines.append(line)
    if current_path is not None:
        sections.append((current_path, current_lines))
    section_paths = [item[0] for item in sections]
    if section_paths != expected_paths:
        fail(
            "patch changed-path set does not equal the declared set: "
            f"expected {expected_paths!r}, got {section_paths!r}"
        )

    forbidden_headers = (
        "deleted file mode ",
        "old mode ",
        "new mode ",
        "rename from ",
        "rename to ",
        "copy from ",
        "copy to ",
        "similarity index ",
        "dissimilarity index ",
        "GIT binary patch",
        "Binary files ",
    )
    for changed_path, section in sections:
        if any(line.startswith(forbidden_headers) for line in section):
            fail(f"source-delta patch changes mode/type, deletes, renames, copies, or embeds binary data: {changed_path}")
        new_modes = [line for line in section if line.startswith("new file mode ")]
        if new_modes and new_modes != ["new file mode 100644"]:
            fail(f"source-delta patch adds a file with an unexpected mode: {changed_path}")
        old_headers = [line for line in section if line.startswith("--- ")]
        new_headers = [line for line in section if line.startswith("+++ ")]
        if len(old_headers) != 1 or len(new_headers) != 1:
            fail(f"source-delta patch has malformed file headers: {changed_path}")
        valid_old = {f"--- a/{changed_path}", "--- /dev/null"}
        if old_headers[0] not in valid_old or new_headers[0] != f"+++ b/{changed_path}":
            fail(f"source-delta patch file headers do not match {changed_path}")
        if not any(line.startswith("@@ ") for line in section):
            fail(f"source-delta patch has no text hunk: {changed_path}")


def validate_declared_contract(args: argparse.Namespace) -> tuple[list[str], dict[str, Any]]:
    paths = checked_paths(args.changed_path)
    validate_digest(args.base_source_id, "base source ID")
    validate_digest(args.candidate_source_id, "candidate source ID")
    validate_digest(args.patch_sha256, "patch SHA-256")
    validate_digest(args.policy_id, "policy ID")
    validate_digest(args.delta_contract_id, "delta contract ID")
    validate_revision(args.base_revision, "base revision")
    validate_revision(args.candidate_revision, "candidate revision")
    if not args.base_source.is_absolute() or not args.candidate_source.is_absolute():
        fail("base and candidate sources must use absolute paths")
    if not args.patch.is_absolute():
        fail("source-delta patch must use an absolute path")
    if args.base_source.resolve() == args.candidate_source.resolve():
        fail("base and candidate source paths must differ")
    if args.base_source_id == args.candidate_source_id:
        fail("base and candidate source IDs must differ")
    if args.base_revision == args.candidate_revision:
        fail("base and candidate revisions must differ")
    policy = policy_contract(args.policy)
    expected_policy_id = policy_id(args.policy)
    if args.policy_id != expected_policy_id:
        fail("declared policy ID does not match the immutable policy")
    if source_id(args.base_source) != args.base_source_id:
        fail("base source ID does not match the immutable base path")
    if source_id(args.candidate_source) != args.candidate_source_id:
        fail("candidate source ID does not match the immutable candidate path")
    if sha256_file(args.patch) != args.patch_sha256:
        fail("source-delta patch SHA-256 does not match the declared hash")
    contract = delta_contract(args, paths)
    if sha256_bytes(canonical(contract)) != args.delta_contract_id:
        fail("delta contract ID does not match the declared contract")
    validate_policy_paths(paths, policy)
    return paths, policy


def make_writable(root: Path) -> None:
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        directory_path.chmod(stat.S_IMODE(directory_path.lstat().st_mode) | stat.S_IWUSR)
        for name in directory_names + file_names:
            path = directory_path / name
            info = path.lstat()
            if not stat.S_ISLNK(info.st_mode):
                path.chmod(stat.S_IMODE(info.st_mode) | stat.S_IWUSR)


def restore_modes(root: Path, candidate_entries: list[dict[str, Any]]) -> None:
    # Files first and directories deepest-first so every path remains writable
    # until its children have been normalized.
    entries = sorted(
        candidate_entries,
        key=lambda entry: (entry["type"] == "directory", -entry["path"].count("/")),
    )
    for entry in entries:
        if entry["type"] == "symlink":
            continue
        (root / entry["path"]).chmod(int(entry["mode"], 8))


def ensure_changed_ancestors_are_directories(
    root: Path, paths: list[str], label: str, allow_missing: bool = False
) -> None:
    for value in paths:
        current = root
        for component in PurePosixPath(value).parts[:-1]:
            current /= component
            try:
                info = current.lstat()
            except FileNotFoundError:
                if allow_missing:
                    break
                fail(f"{label} changed-path ancestor is missing: {current}")
            except OSError as error:
                fail(f"cannot inspect {label} changed-path ancestor {current}: {error}")
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                fail(f"{label} changed-path ancestor is not a real directory: {current}")


def apply_patch(base: Path, patch: Path, destination: Path) -> None:
    shutil.copytree(base, destination, symlinks=True, copy_function=shutil.copy2)
    make_writable(destination)
    environment = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": str(destination.parent / ".git-home"),
        "GIT_CONFIG_NOSYSTEM": "1",
        "LC_ALL": "C.UTF-8",
    }
    Path(environment["HOME"]).mkdir()
    command = [
        "git",
        "-c",
        "core.safecrlf=true",
        "apply",
        "--binary",
        "--whitespace=error-all",
    ]
    try:
        subprocess.run(command + ["--check", str(patch)], cwd=destination, env=environment, check=True)
        subprocess.run(command + [str(patch)], cwd=destination, env=environment, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"source-delta patch does not apply strictly to the base tree: {error}")


def build_verified_tree(
    args: argparse.Namespace, destination: Path
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    paths, policy = validate_declared_contract(args)
    require_plain_directory(args.base_source, "base source")
    require_plain_directory(args.candidate_source, "candidate source")
    parse_patch(args.patch, paths)
    base_entries = tree_manifest(args.base_source, "base source")
    candidate_entries = tree_manifest(args.candidate_source, "candidate source")
    actual_changed_paths = changed_leaf_paths(base_entries, candidate_entries)
    if actual_changed_paths != paths:
        fail(
            "candidate changed-path set does not equal the declared set: "
            f"expected {paths!r}, got {actual_changed_paths!r}"
        )
    changes = validate_change_modes(paths, base_entries, candidate_entries, policy)
    ensure_changed_ancestors_are_directories(
        args.base_source, paths, "base source", allow_missing=True
    )
    ensure_changed_ancestors_are_directories(args.candidate_source, paths, "candidate source")
    apply_patch(args.base_source, args.patch, destination)
    restore_modes(destination, candidate_entries)
    post_entries = tree_manifest(destination, "patched postimage")
    if post_entries != candidate_entries:
        fail("patched complete tree is not byte/type/mode-for-byte identical to the candidate")
    return candidate_entries, changes, base_entries


def write_canonical(path: Path, value: Any) -> str:
    data = canonical(value, newline=True)
    path.write_bytes(data)
    return sha256_bytes(data)


def generated_metadata(
    args: argparse.Namespace,
    proof: Path,
    candidate_entries: list[dict[str, Any]],
    changes: list[dict[str, Any]],
    base_entries: list[dict[str, Any]],
    tree_manifest_sha256: str,
) -> dict[str, Any]:
    source_path = proof / "source"
    return {
        "schemaVersion": 1,
        "api": "coyote-nix.coyote-source-delta/v1",
        "kind": "coyote-source-delta-proof",
        "failClosed": True,
        "outcome": "accepted",
        "policy": {"name": args.policy, "id": args.policy_id},
        "contractId": args.delta_contract_id,
        "base": {
            "sourceId": args.base_source_id,
            "revision": args.base_revision,
            "treeManifestSha256": sha256_bytes(canonical(base_entries, newline=True)),
        },
        "candidate": {
            "sourceId": args.candidate_source_id,
            "revision": args.candidate_revision,
            "treeManifestSha256": tree_manifest_sha256,
        },
        "effective": {
            "sourceId": source_id(source_path),
            "treeManifestSha256": tree_manifest_sha256,
        },
        "patch": {"sha256": args.patch_sha256},
        "changedPaths": changes,
        "treeManifest": {
            "path": "metadata/tree-manifest.json",
            "sha256": tree_manifest_sha256,
            "entryCount": len(candidate_entries),
        },
    }


def completion_record(metadata: dict[str, Any], metadata_sha256: str) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "api": "coyote-nix.coyote-source-delta-completion/v1",
        "failClosed": True,
        "outcome": "accepted",
        "baseSourceId": metadata["base"]["sourceId"],
        "effectiveSourceId": metadata["effective"]["sourceId"],
        "candidateSourceId": metadata["candidate"]["sourceId"],
        "baseRevision": metadata["base"]["revision"],
        "candidateRevision": metadata["candidate"]["revision"],
        "patchSha256": metadata["patch"]["sha256"],
        "changedPaths": metadata["changedPaths"],
        "treeManifestSha256": metadata["treeManifest"]["sha256"],
        "deltaContractId": metadata["contractId"],
        "policyId": metadata["policy"]["id"],
        "metadataSha256": metadata_sha256,
    }


def command_apply(args: argparse.Namespace) -> None:
    if args.output.exists():
        fail(f"source-delta output already exists: {args.output}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="coyote-source-delta-") as temporary:
        postimage = Path(temporary) / "source"
        candidate_entries, changes, base_entries = build_verified_tree(args, postimage)
        args.output.mkdir()
        shutil.copytree(postimage, args.output / "source", symlinks=True, copy_function=shutil.copy2)
        metadata_directory = args.output / "metadata"
        metadata_directory.mkdir()
        tree_hash = write_canonical(metadata_directory / "tree-manifest.json", candidate_entries)
        metadata = generated_metadata(
            args,
            args.output,
            candidate_entries,
            changes,
            base_entries,
            tree_hash,
        )
        metadata_hash = write_canonical(metadata_directory / "delta.json", metadata)
        completion = completion_record(metadata, metadata_hash)
        temporary_marker = metadata_directory / ".complete.json.tmp"
        write_canonical(temporary_marker, completion)
        os.replace(temporary_marker, metadata_directory / "complete.json")


def read_canonical_json(path: Path, label: str) -> Any:
    require_plain_file(path, label)
    try:
        data = path.read_bytes()
        value = json.loads(data)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"cannot read {label}: {error}")
    if data != canonical(value, newline=True):
        fail(f"{label} is not canonical JSON")
    return value


def command_verify(args: argparse.Namespace) -> None:
    require_plain_directory(args.proof, "source-delta proof")
    entries = {entry.name for entry in os.scandir(args.proof)}
    if entries != REQUIRED_PROOF_ENTRIES:
        fail(f"source-delta proof has unexpected top-level entries: {sorted(entries)!r}")
    metadata_directory = args.proof / "metadata"
    require_plain_directory(metadata_directory, "source-delta metadata")
    metadata_entries = {entry.name for entry in os.scandir(metadata_directory)}
    if metadata_entries != REQUIRED_METADATA_ENTRIES:
        fail(f"source-delta proof has unexpected metadata entries: {sorted(metadata_entries)!r}")

    with tempfile.TemporaryDirectory(prefix="coyote-source-delta-verify-") as temporary:
        postimage = Path(temporary) / "source"
        candidate_entries, changes, base_entries = build_verified_tree(args, postimage)
        proof_entries = tree_manifest(args.proof / "source", "effective source")
        if proof_entries != candidate_entries:
            fail("effective proof source is not byte/type/mode-for-byte identical to the verified postimage")

    manifest_path = metadata_directory / "tree-manifest.json"
    stored_manifest = read_canonical_json(manifest_path, "source-delta tree manifest")
    if stored_manifest != candidate_entries:
        fail("stored tree manifest does not describe the effective source")
    manifest_hash = sha256_file(manifest_path)
    expected_metadata = generated_metadata(
        args,
        args.proof,
        candidate_entries,
        changes,
        base_entries,
        manifest_hash,
    )
    metadata_path = metadata_directory / "delta.json"
    metadata = read_canonical_json(metadata_path, "source-delta metadata")
    if metadata != expected_metadata:
        fail("source-delta metadata does not match the verified contract and trees")
    metadata_hash = sha256_file(metadata_path)
    completion = read_canonical_json(
        metadata_directory / "complete.json", "source-delta completion marker"
    )
    if completion != completion_record(expected_metadata, metadata_hash):
        fail("source-delta completion marker does not match the verified metadata")


def add_contract_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--base-source", required=True, type=Path)
    parser.add_argument("--candidate-source", required=True, type=Path)
    parser.add_argument("--patch", required=True, type=Path)
    parser.add_argument("--base-source-id", required=True)
    parser.add_argument("--candidate-source-id", required=True)
    parser.add_argument("--base-revision", required=True)
    parser.add_argument("--candidate-revision", required=True)
    parser.add_argument("--patch-sha256", required=True)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--policy-id", required=True)
    parser.add_argument("--delta-contract-id", required=True)
    parser.add_argument("--changed-path", action="append", default=[], required=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    apply_parser = subparsers.add_parser("apply")
    add_contract_arguments(apply_parser)
    apply_parser.add_argument("--output", required=True, type=Path)
    verify_parser = subparsers.add_parser("verify")
    add_contract_arguments(verify_parser)
    verify_parser.add_argument("--proof", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "apply":
            command_apply(args)
        else:
            command_verify(args)
    except (DeltaError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
