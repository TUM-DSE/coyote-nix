#!/usr/bin/env python3
"""Positive and fail-closed contracts for matched implementation evidence."""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from jsonschema import Draft202012Validator, ValidationError

REQUEST_API = "coyote-nix.matched-implementation-request/v1"
PROVENANCE_API = "coyote-nix.implementation-report-provenance/v1"
REPORT_NAMES = ("timing", "latency", "utilization")
REVISIONS = {
    "decoder": "1" * 40,
    "coyote": "2" * 40,
    "coyote-nix": "3" * 40,
    "qshell": "4" * 40,
}
SOURCE_HASHES = {
    "decoder": "a" * 64,
    "coyote": "b" * 64,
    "coyote-nix": "c" * 64,
    "qshell": "d" * 64,
}


def canonical(document):
    return (
        json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        + "\n"
    ).encode()


def write_json(path, document):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical(document))


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_records(deployment):
    roles = ["decoder", "coyote", "coyote-nix"]
    if deployment == "qshell":
        roles.append("qshell")
    # Deliberately reverse the input order; normalized evidence must sort by role.
    return [
        {
            "role": role,
            "repository": f"https://example.invalid/{role}.git",
            "revision": REVISIONS[role],
            "sourceSha256": SOURCE_HASHES[role],
        }
        for role in reversed(roles)
    ]


def report_descriptors(root):
    return {
        name: {
            "path": f"reports/{name}.{'json' if name == 'latency' else 'rpt'}",
            "sha256": sha256(
                root / f"reports/{name}.{'json' if name == 'latency' else 'rpt'}"
            ),
        }
        for name in REPORT_NAMES
    }


def write_request(pair):
    document = {
        "schemaVersion": 1,
        "api": REQUEST_API,
        "baseline": {
            "packageRoot": str(pair["baseline"]),
            "provenance": {
                "path": "metadata/provenance.json",
                "sha256": sha256(pair["baseline"] / "metadata/provenance.json"),
            },
        },
        "qshell": {
            "packageRoot": str(pair["qshell"]),
            "provenance": {
                "path": "metadata/provenance.json",
                "sha256": sha256(pair["qshell"] / "metadata/provenance.json"),
            },
        },
    }
    write_json(pair["request"], document)


def create_pair(root, fixtures, board):
    definition = load_json(fixtures / board / "definition.json")
    version = "2023.2" if board == "u280" else "2025.1"
    strategy_id = ("9" if board == "u280" else "e") * 64
    pair = {
        "request": root / "request.json",
        "baseline": root / "baseline",
        "qshell": root / "qshell",
    }
    for role, deployment, fixture_name in (
        ("baseline", "standalone-coyote", "standalone"),
        ("qshell", "qshell", "qshell"),
    ):
        package_root = pair[role]
        (package_root / "reports").mkdir(parents=True)
        for name in REPORT_NAMES:
            extension = "json" if name == "latency" else "rpt"
            shutil.copyfile(
                fixtures / board / fixture_name / f"{name}.{extension}",
                package_root / "reports" / f"{name}.{extension}",
            )
        provenance = {
            "schemaVersion": 1,
            "api": PROVENANCE_API,
            "deployment": deployment,
            "packageName": f"fixture-{board}-{deployment}",
            "definition": copy.deepcopy(definition),
            "build": {
                "strategyId": strategy_id,
                "tool": {"name": "vivado", "version": version},
                "outcome": "accepted",
            },
            "sources": source_records(deployment),
            "reports": report_descriptors(package_root),
        }
        write_json(package_root / "metadata/provenance.json", provenance)
    write_request(pair)
    return pair


def refresh_report_hashes(pair, role):
    root = pair[role]
    path = root / "metadata/provenance.json"
    provenance = load_json(path)
    provenance["reports"] = report_descriptors(root)
    write_json(path, provenance)
    write_request(pair)


def mutate_provenance(pair, role, mutation):
    path = pair[role] / "metadata/provenance.json"
    document = load_json(path)
    mutation(document)
    write_json(path, document)
    write_request(pair)


def mutate_latency(pair, role, mutation):
    path = pair[role] / "reports/latency.json"
    document = load_json(path)
    mutation(document)
    write_json(path, document)
    refresh_report_hashes(pair, role)


def mutate_report_text(pair, role, name, old, new):
    extension = "json" if name == "latency" else "rpt"
    path = pair[role] / "reports" / f"{name}.{extension}"
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise AssertionError(f"fixture mutation text is absent: {old!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    refresh_report_hashes(pair, role)


def invoke(tool, request, output=None):
    command = [str(tool), "compare", str(request)]
    if output is not None:
        command.extend(("--output", str(output)))
    return subprocess.run(command, check=False, capture_output=True)


def expect_failure(tool, pair, message):
    result = invoke(tool, pair["request"])
    if result.returncode == 0:
        raise AssertionError(f"unexpected comparison success; wanted {message!r}")
    stderr = result.stderr.decode()
    if message not in stderr:
        raise AssertionError(
            f"missing failure {message!r}; stderr was {stderr.strip()!r}"
        )


def verify_identity(document, field):
    copy_without_id = copy.deepcopy(document)
    observed = copy_without_id.pop(field)
    expected = hashlib.sha256(canonical(copy_without_id)).hexdigest()
    if observed != expected:
        raise AssertionError(f"{field} does not bind canonical document")


def positive_case(tool, validator, fixtures, root, board):
    pair = create_pair(root, fixtures, board)
    stdout_run = invoke(tool, pair["request"])
    if stdout_run.returncode != 0:
        raise AssertionError(stdout_run.stderr.decode())
    first = json.loads(stdout_run.stdout)
    validator.validate(first)

    output = root / "evidence.json"
    file_run = invoke(tool, pair["request"], output)
    if file_run.returncode != 0:
        raise AssertionError(file_run.stderr.decode())
    if output.read_bytes() != stdout_run.stdout:
        raise AssertionError("stdout and atomic file output differ")
    if invoke(tool, pair["request"]).stdout != stdout_run.stdout:
        raise AssertionError("comparison output is not deterministic")

    verify_identity(first, "comparisonId")
    verify_identity(first["records"]["baseline"], "recordId")
    verify_identity(first["records"]["qshell"], "recordId")
    if [
        item["role"] for item in first["records"]["baseline"]["provenance"]["sources"]
    ] != [
        "coyote",
        "coyote-nix",
        "decoder",
    ]:
        raise AssertionError("baseline sources are not normalized by role")

    total = first["overhead"]["latency"]["total"]
    if total["delta"] != {
        "sampleCount": 3 if board == "u280" else 4,
        "minimumFs": 18_000_000,
        "maximumFs": 18_000_000,
        "sumFs": 54_000_000 if board == "u280" else 72_000_000,
        "p50Fs": 18_000_000,
        "p99Fs": 18_000_000,
    }:
        raise AssertionError(f"unexpected {board} paired latency overhead: {total}")
    components = first["overhead"]["latency"]["components"]
    expected_component_delta = {
        "peer": 2_000_000 if board == "u280" else 0,
        "dispatch": 8_000_000,
        "queue": 4_000_000,
        "decoder": 0,
        "return": 4_000_000 if board == "u280" else 6_000_000,
    }
    for name, expected in expected_component_delta.items():
        if components[name]["delta"]["p99Fs"] != expected:
            raise AssertionError(f"unexpected {board} {name} latency delta")
    if board == "u280":
        if first["records"]["qshell"]["timing"]["setup"]["wnsFs"] != 29_000:
            raise AssertionError("U280 Vivado timing was not parsed in femtoseconds")
        if first["overhead"]["utilization"]["lut"]["delta"] != 25_224:
            raise AssertionError("U280 LUT overhead is incorrect")
        if first["overhead"]["utilization"]["uram"]["relative"] != {
            "state": "unavailable",
            "reason": "zero-baseline",
        }:
            raise AssertionError("zero baseline utilization was not explicit")
    else:
        if first["records"]["qshell"]["timing"]["hold"]["wnsFs"] != 12_000:
            raise AssertionError("V80 Vivado timing was not parsed in femtoseconds")
        if first["overhead"]["utilization"]["bramTiles"]["delta"] != 17_500:
            raise AssertionError("fractional V80 BRAM tiles were not preserved")
        if first["match"]["peer"] != {
            "definitionId": "8" * 64,
            "mode": "none",
            "included": False,
        }:
            raise AssertionError("no-peer definition was not preserved")

    invalid = copy.deepcopy(first)
    invalid["records"]["qshell"]["timing"]["unexpected"] = True
    try:
        validator.validate(invalid)
    except ValidationError:
        pass
    else:
        raise AssertionError("strict schema accepted a nested unknown property")


def negative_cases(tool, fixtures, root):
    match_mutations = {
        "board": lambda value: value["definition"]["board"].__setitem__(
            "name", "u280-other"
        ),
        "distance": lambda value: value["definition"].__setitem__("distance", 11),
        "decoder": lambda value: value["definition"]["decoder"].__setitem__(
            "variant", "different-rtl"
        ),
        "clock": lambda value: value["definition"]["clock"].__setitem__(
            "decoderHz", 250_000_000
        ),
        "peer": lambda value: value["definition"]["peer"].__setitem__(
            "mode", "different-peer"
        ),
    }
    for field, mutation in match_mutations.items():
        pair = create_pair(root / f"mismatch-{field}", fixtures, "u280")
        mutate_provenance(pair, "qshell", mutation)
        expect_failure(tool, pair, f"comparison definition mismatch: {field}")

    pair = create_pair(root / "strategy", fixtures, "u280")
    mutate_provenance(
        pair,
        "qshell",
        lambda value: value["build"].__setitem__("strategyId", "f" * 64),
    )
    expect_failure(tool, pair, "comparison build strategy mismatch")

    pair = create_pair(root / "trace", fixtures, "u280")
    mutate_latency(pair, "qshell", lambda value: value.__setitem__("traceId", "f" * 64))
    expect_failure(tool, pair, "comparison latency trace mismatch")

    pair = create_pair(root / "sample", fixtures, "u280")
    mutate_latency(
        pair,
        "qshell",
        lambda value: value["samples"][1].__setitem__("requestSha256", "f" * 64),
    )
    expect_failure(tool, pair, "comparison latency sample/request set mismatch")

    pair = create_pair(root / "outcome", fixtures, "u280")
    mutate_provenance(
        pair,
        "qshell",
        lambda value: value["build"].__setitem__("outcome", "rejected"),
    )
    expect_failure(tool, pair, "qshell implementation outcome is not accepted")

    pair = create_pair(root / "unrouted", fixtures, "u280")
    mutate_report_text(
        pair,
        "qshell",
        "timing",
        "Design State      : Routed",
        "Design State      : Unrouted",
    )
    expect_failure(tool, pair, "qshell timing report is not from a routed design")

    pair = create_pair(root / "negative-timing", fixtures, "u280")
    mutate_report_text(
        pair,
        "qshell",
        "timing",
        "0.029        0.000                      0               638794",
        "-0.100       -1.000                     10               638794",
    )
    expect_failure(tool, pair, "qshell implementation does not meet timing")

    pair = create_pair(root / "inconsistent-timing", fixtures, "u280")
    mutate_report_text(
        pair,
        "qshell",
        "timing",
        "0.029        0.000                      0               638794",
        "0.029       -1.000                      0               638794",
    )
    expect_failure(
        tool, pair, "setup timing values conflict with zero failing endpoints"
    )

    pair = create_pair(root / "nonmonotonic", fixtures, "u280")
    mutate_latency(
        pair,
        "qshell",
        lambda value: value["samples"][0]["boundariesFs"].__setitem__(
            "dispatchComplete", 1_009_000_000
        ),
    )
    expect_failure(tool, pair, "boundary timestamps are not monotonic")

    pair = create_pair(root / "capacity", fixtures, "u280")
    mutate_report_text(pair, "qshell", "utilization", "1303680", "1303681")
    expect_failure(tool, pair, "utilization device capacity mismatch: lut")

    pair = create_pair(root / "unknown-provenance", fixtures, "u280")
    mutate_provenance(
        pair, "qshell", lambda value: value.__setitem__("unexpected", True)
    )
    expect_failure(tool, pair, "qshell provenance has unexpected fields")

    pair = create_pair(root / "tampered-report", fixtures, "u280")
    with (pair["qshell"] / "reports/timing.rpt").open("a", encoding="utf-8") as stream:
        stream.write("tamper\n")
    expect_failure(tool, pair, "qshell timing report hash mismatch")

    pair = create_pair(root / "duplicate-key", fixtures, "u280")
    request = pair["request"].read_text(encoding="utf-8")
    pair["request"].write_text(
        request.replace(
            f'"api":"{REQUEST_API}"',
            f'"api":"{REQUEST_API}","api":"{REQUEST_API}"',
            1,
        ),
        encoding="utf-8",
    )
    expect_failure(tool, pair, "duplicate JSON key: api")

    pair = create_pair(root / "unsafe-path", fixtures, "u280")
    mutate_provenance(
        pair,
        "qshell",
        lambda value: value["reports"]["timing"].__setitem__("path", "../timing.rpt"),
    )
    expect_failure(tool, pair, "is unsafe or non-canonical")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("tool", type=Path)
    parser.add_argument("schema", type=Path)
    parser.add_argument("fixtures", type=Path)
    args = parser.parse_args()

    schema = load_json(args.schema)
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    with tempfile.TemporaryDirectory(prefix="coyote-report-evidence-") as temporary:
        root = Path(temporary).resolve()
        positive_case(args.tool, validator, args.fixtures, root / "u280", "u280")
        positive_case(args.tool, validator, args.fixtures, root / "v80", "v80")
        negative_cases(args.tool, args.fixtures, root / "negative")
    print("coyote report evidence contract: PASS")


if __name__ == "__main__":
    main()
