#!/usr/bin/env python3
"""Normalize and compare immutable standalone-Coyote and QShell reports."""

import argparse
from decimal import Decimal, InvalidOperation
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tempfile

REQUEST_API = "coyote-nix.matched-implementation-request/v1"
PROVENANCE_API = "coyote-nix.implementation-report-provenance/v1"
LATENCY_API = "coyote-nix.latency-boundary-samples/v1"
OUTPUT_API = "coyote-nix.matched-implementation-evidence/v1"
OUTPUT_KIND = "matched-standalone-coyote-qshell-evidence"
BOUNDARY_DEFINITION = "last-input-handshake-to-complete-correction-presentation/v1"
BOUNDARIES = (
    "inputComplete",
    "peerComplete",
    "dispatchComplete",
    "queueComplete",
    "decoderComplete",
    "outputComplete",
)
COMPONENT_BOUNDARIES = {
    "peer": ("inputComplete", "peerComplete"),
    "dispatch": ("peerComplete", "dispatchComplete"),
    "queue": ("dispatchComplete", "queueComplete"),
    "decoder": ("queueComplete", "decoderComplete"),
    "return": ("decoderComplete", "outputComplete"),
}
MATCH_FIELDS = ("board", "distance", "decoder", "clock", "peer")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SOURCE_REVISION_RE = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
DECIMAL_RE = re.compile(r"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$")
ROLE_RE = re.compile(r"^[a-z][a-z0-9-]*$")
MAX_TIME_FS = (1 << 63) - 1


class EvidenceError(ValueError):
    """A report or contract failed validation."""


def fail(message: str) -> None:
    raise EvidenceError(message)


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_json_constant(value):
    fail(f"non-finite JSON value: {value}")


def load_json(path: Path):
    try:
        with path.open("r", encoding="utf-8") as stream:
            return json.load(
                stream,
                object_pairs_hook=strict_object,
                parse_constant=reject_json_constant,
            )
    except EvidenceError:
        raise
    except (OSError, json.JSONDecodeError, ValueError) as error:
        fail(f"cannot read JSON {path}: {error}")


def canonical(value) -> bytes:
    try:
        encoded = json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        )
    except (TypeError, ValueError) as error:
        fail(f"cannot encode canonical JSON: {error}")
    return (encoded + "\n").encode()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        fail(f"cannot hash {path}: {error}")
    return digest.hexdigest()


def exact_object(value, keys, field: str):
    if not isinstance(value, dict):
        fail(f"{field} must be an object")
    expected = set(keys)
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        fail(f"{field} has unexpected fields (missing={missing}, extra={extra})")
    return value


def nonempty_string(value, field: str) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        fail(f"{field} must be a non-empty, trimmed string")
    return value


def sha256_string(value, field: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        fail(f"{field} must be a lowercase SHA-256 value")
    return value


def positive_integer(value, field: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        fail(f"{field} must be a positive integer")
    return value


def nonnegative_integer(value, field: str, maximum=None) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        fail(f"{field} must be a non-negative integer")
    if maximum is not None and value > maximum:
        fail(f"{field} exceeds the supported maximum")
    return value


def safe_relative(raw, field: str) -> PurePosixPath:
    if not isinstance(raw, str) or not raw:
        fail(f"{field} must be a non-empty relative path")
    path = PurePosixPath(raw)
    if (
        path.is_absolute()
        or "." in path.parts
        or ".." in path.parts
        or str(path) != raw
    ):
        fail(f"{field} is unsafe or non-canonical: {raw}")
    return path


def resolve_contained(root: Path, raw, field: str) -> tuple[Path, str]:
    relative = safe_relative(raw, field)
    try:
        root_real = root.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve package root {root}: {error}")
    if not root_real.is_dir():
        fail(f"package root is not a directory: {root_real}")
    candidate = root_real.joinpath(*relative.parts)
    try:
        candidate_real = candidate.resolve(strict=True)
    except OSError as error:
        fail(f"missing {field} {relative}: {error}")
    try:
        candidate_real.relative_to(root_real)
    except ValueError:
        fail(f"{field} escapes package root: {relative}")
    if not candidate_real.is_file():
        fail(f"{field} is not a regular file: {relative}")
    return candidate_real, str(relative)


def resolve_hashed_artifact(root: Path, descriptor, field: str):
    exact_object(descriptor, ("path", "sha256"), field)
    expected_sha256 = sha256_string(descriptor["sha256"], f"{field}.sha256")
    path, relative = resolve_contained(root, descriptor["path"], f"{field}.path")
    actual_sha256 = sha256_file(path)
    if actual_sha256 != expected_sha256:
        fail(f"{field} hash mismatch: expected {expected_sha256}, got {actual_sha256}")
    return path, {
        "path": relative,
        "sha256": actual_sha256,
        "bytes": path.stat().st_size,
    }


def decimal_scaled_integer(value: str, scale: int, field: str) -> int:
    if not isinstance(value, str) or DECIMAL_RE.fullmatch(value) is None:
        fail(f"{field} is not a canonical decimal")
    try:
        decimal = Decimal(value)
    except InvalidOperation:
        fail(f"{field} is not a decimal number")
    scaled = decimal * scale
    if not scaled.is_finite() or scaled != scaled.to_integral_value():
        fail(f"{field} cannot be represented in the canonical unit")
    return int(scaled)


def report_header_value(lines, name: str, field: str) -> str:
    pattern = re.compile(rf"^\|\s*{re.escape(name)}\s*:\s*(.*?)\s*\|?\s*$")
    values = []
    for line in lines:
        match = pattern.match(line)
        if match:
            value = match.group(1).strip()
            if value.endswith("|"):
                value = value[:-1].rstrip()
            values.append(value)
    if len(values) != 1 or not values[0]:
        fail(f"{field} must occur exactly once in its report")
    return values[0]


def parse_tool_version(raw: str, field: str) -> str:
    match = re.search(r"\bVivado\s+v\.?([0-9]+\.[0-9]+)\b", raw)
    if match is None:
        fail(f"{field} does not identify a supported Vivado version")
    return match.group(1)


def device_matches(expected: str, observed: str) -> bool:
    return (
        expected == observed
        or expected.startswith(observed + "-")
        or observed.startswith(expected + "-")
    )


def parse_timing_report(path: Path):
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as error:
        fail(f"cannot read timing report {path}: {error}")
    tool_raw = report_header_value(lines, "Tool Version", "timing Tool Version")
    device = nonempty_string(
        report_header_value(lines, "Device", "timing Device").split()[0],
        "timing Device",
    )
    design_state = report_header_value(lines, "Design State", "timing Design State")
    summary_markers = [
        index
        for index, line in enumerate(lines)
        if line.strip() == "| Design Timing Summary"
    ]
    if len(summary_markers) != 1:
        fail("timing report must contain exactly one Design Timing Summary")
    start = summary_markers[0]
    header_indices = [
        index
        for index in range(start + 1, min(len(lines), start + 16))
        if "WNS(ns)" in lines[index]
        and "TNS(ns)" in lines[index]
        and "WHS(ns)" in lines[index]
        and "THS(ns)" in lines[index]
    ]
    if len(header_indices) != 1:
        fail("timing summary has no unambiguous WNS/TNS/WHS/THS header")
    numeric_rows = []
    for line in lines[header_indices[0] + 1 : header_indices[0] + 8]:
        cells = line.split()
        if len(cells) < 8:
            continue
        if all(DECIMAL_RE.fullmatch(cells[index]) for index in (0, 1, 4, 5)) and all(
            re.fullmatch(r"[0-9]+", cells[index]) for index in (2, 3, 6, 7)
        ):
            numeric_rows.append(cells)
    if len(numeric_rows) != 1:
        fail("timing summary has no unambiguous numeric result row")
    cells = numeric_rows[0]
    setup_wns = decimal_scaled_integer(cells[0], 1_000_000, "setup WNS")
    setup_tns = decimal_scaled_integer(cells[1], 1_000_000, "setup TNS")
    hold_wns = decimal_scaled_integer(cells[4], 1_000_000, "hold WNS")
    hold_tns = decimal_scaled_integer(cells[5], 1_000_000, "hold TNS")
    setup_failing = int(cells[2])
    setup_total = int(cells[3])
    hold_failing = int(cells[6])
    hold_total = int(cells[7])
    if setup_failing > setup_total or hold_failing > hold_total:
        fail("timing summary failing endpoints exceed total endpoints")
    for name, wns, tns, failing in (
        ("setup", setup_wns, setup_tns, setup_failing),
        ("hold", hold_wns, hold_tns, hold_failing),
    ):
        if tns > 0:
            fail(f"{name} TNS must not be positive")
        if failing == 0 and (wns < 0 or tns != 0):
            fail(f"{name} timing values conflict with zero failing endpoints")
        if failing > 0 and (wns >= 0 or tns >= 0):
            fail(f"{name} timing values conflict with failing endpoints")
    timing_met = setup_failing == 0 and hold_failing == 0
    return {
        "toolVersion": parse_tool_version(tool_raw, "timing Tool Version"),
        "device": device,
        "designState": nonempty_string(design_state, "timing Design State"),
        "setup": {
            "wnsFs": setup_wns,
            "tnsFs": setup_tns,
            "failingEndpoints": setup_failing,
            "totalEndpoints": setup_total,
        },
        "hold": {
            "wnsFs": hold_wns,
            "tnsFs": hold_tns,
            "failingEndpoints": hold_failing,
            "totalEndpoints": hold_total,
        },
        "met": timing_met,
    }


def parse_utilization_report(path: Path):
    aliases = {
        "CLB LUTs": ("lut", "count", 1),
        "Slice LUTs": ("lut", "count", 1),
        "Registers": ("register", "count", 1),
        "CLB Registers": ("register", "count", 1),
        "Slice Registers": ("register", "count", 1),
        "Block RAM Tile": ("bramTiles", "milli-tile", 1000),
        "URAM": ("uram", "count", 1),
        "DSP Slices": ("dsp", "count", 1),
        "DSPs": ("dsp", "count", 1),
    }
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as error:
        fail(f"cannot read utilization report {path}: {error}")
    tool_raw = report_header_value(lines, "Tool Version", "utilization Tool Version")
    device = nonempty_string(
        report_header_value(lines, "Device", "utilization Device").split()[0],
        "utilization Device",
    )
    header = None
    resources = {}
    for line in lines:
        stripped = line.strip()
        if not stripped.startswith("|") or not stripped.endswith("|"):
            continue
        cells = [cell.strip() for cell in stripped[1:-1].split("|")]
        lowered = [cell.lower() for cell in cells]
        if "site type" in lowered and "used" in lowered and "available" in lowered:
            header = {
                "label": lowered.index("site type"),
                "used": lowered.index("used"),
                "available": lowered.index("available"),
            }
            continue
        if header is None or max(header.values()) >= len(cells):
            continue
        label = re.sub(r"\*+$", "", cells[header["label"]]).strip()
        if label not in aliases:
            continue
        key, unit, scale = aliases[label]
        used_raw = cells[header["used"]].replace(",", "")
        available_raw = cells[header["available"]].replace(",", "")
        if used_raw in ("", "-", "N/A") or available_raw in ("", "-", "N/A"):
            continue
        observation = {
            "used": decimal_scaled_integer(
                used_raw, scale, f"utilization {label} used"
            ),
            "available": decimal_scaled_integer(
                available_raw, scale, f"utilization {label} available"
            ),
            "unit": unit,
        }
        if observation["used"] < 0 or observation["available"] <= 0:
            fail(f"utilization {label} has invalid used or available capacity")
        if observation["used"] > observation["available"]:
            fail(f"utilization {label} exceeds available capacity")
        if key in resources and resources[key] != observation:
            fail(f"utilization report contains conflicting {key} rows")
        resources[key] = observation
    required = {"lut", "register", "bramTiles", "uram", "dsp"}
    if set(resources) != required:
        missing = sorted(required - set(resources))
        fail(f"utilization report is incomplete (missing={missing})")
    return {
        "toolVersion": parse_tool_version(tool_raw, "utilization Tool Version"),
        "device": device,
        "resources": resources,
    }


def validate_definition(value, field: str):
    definition = exact_object(value, MATCH_FIELDS, field)
    board = exact_object(definition["board"], ("name", "part"), f"{field}.board")
    nonempty_string(board["name"], f"{field}.board.name")
    nonempty_string(board["part"], f"{field}.board.part")
    positive_integer(definition["distance"], f"{field}.distance")
    decoder = exact_object(
        definition["decoder"],
        ("family", "variant", "rtlSha256", "graphSha256"),
        f"{field}.decoder",
    )
    nonempty_string(decoder["family"], f"{field}.decoder.family")
    nonempty_string(decoder["variant"], f"{field}.decoder.variant")
    sha256_string(decoder["rtlSha256"], f"{field}.decoder.rtlSha256")
    sha256_string(decoder["graphSha256"], f"{field}.decoder.graphSha256")
    clock = exact_object(
        definition["clock"],
        ("definitionId", "shellHz", "decoderHz"),
        f"{field}.clock",
    )
    sha256_string(clock["definitionId"], f"{field}.clock.definitionId")
    positive_integer(clock["shellHz"], f"{field}.clock.shellHz")
    positive_integer(clock["decoderHz"], f"{field}.clock.decoderHz")
    peer = exact_object(
        definition["peer"],
        ("definitionId", "mode", "included"),
        f"{field}.peer",
    )
    sha256_string(peer["definitionId"], f"{field}.peer.definitionId")
    nonempty_string(peer["mode"], f"{field}.peer.mode")
    if not isinstance(peer["included"], bool):
        fail(f"{field}.peer.included must be Boolean")
    if (peer["mode"] == "none") != (not peer["included"]):
        fail(f"{field}.peer mode and included flag are inconsistent")
    return definition


def validate_build(value, field: str):
    build = exact_object(value, ("strategyId", "tool", "outcome"), field)
    sha256_string(build["strategyId"], f"{field}.strategyId")
    tool = exact_object(build["tool"], ("name", "version"), f"{field}.tool")
    if nonempty_string(tool["name"], f"{field}.tool.name") != "vivado":
        fail(f"{field}.tool.name must be vivado")
    nonempty_string(tool["version"], f"{field}.tool.version")
    if build["outcome"] not in ("accepted", "rejected"):
        fail(f"{field}.outcome must be accepted or rejected")
    return build


def validate_sources(value, deployment: str, field: str):
    if not isinstance(value, list) or not value:
        fail(f"{field} must be a non-empty array")
    sources = []
    roles = set()
    for index, item in enumerate(value):
        item_field = f"{field}[{index}]"
        source = exact_object(
            item,
            ("role", "repository", "revision", "sourceSha256"),
            item_field,
        )
        role = nonempty_string(source["role"], f"{item_field}.role")
        if ROLE_RE.fullmatch(role) is None or role in roles:
            fail(f"{item_field}.role is invalid or duplicated: {role}")
        roles.add(role)
        nonempty_string(source["repository"], f"{item_field}.repository")
        revision = nonempty_string(source["revision"], f"{item_field}.revision")
        if SOURCE_REVISION_RE.fullmatch(revision) is None:
            fail(f"{item_field}.revision must be a full Git object ID")
        sha256_string(source["sourceSha256"], f"{item_field}.sourceSha256")
        sources.append(source)
    required = {"decoder", "coyote", "coyote-nix"}
    if not required.issubset(roles):
        fail(f"{field} is missing required roles: {sorted(required - roles)}")
    if deployment == "qshell" and "qshell" not in roles:
        fail(f"{field} is missing the qshell source role")
    return sorted(sources, key=lambda source: source["role"])


def validate_provenance(value, expected_deployment: str):
    provenance = exact_object(
        value,
        (
            "schemaVersion",
            "api",
            "deployment",
            "packageName",
            "definition",
            "build",
            "sources",
            "reports",
        ),
        f"{expected_deployment} provenance",
    )
    if provenance["schemaVersion"] != 1 or provenance["api"] != PROVENANCE_API:
        fail(f"unsupported {expected_deployment} provenance API")
    if provenance["deployment"] != expected_deployment:
        fail(
            f"{expected_deployment} provenance deployment is "
            f"{provenance['deployment']!r}"
        )
    nonempty_string(provenance["packageName"], "provenance.packageName")
    validate_definition(provenance["definition"], "provenance.definition")
    validate_build(provenance["build"], "provenance.build")
    sources = validate_sources(
        provenance["sources"], expected_deployment, "provenance.sources"
    )
    reports = exact_object(
        provenance["reports"],
        ("timing", "latency", "utilization"),
        "provenance.reports",
    )
    paths = set()
    for role, descriptor in reports.items():
        exact_object(descriptor, ("path", "sha256"), f"provenance.reports.{role}")
        relative = str(
            safe_relative(descriptor["path"], f"provenance.reports.{role}.path")
        )
        if relative in paths:
            fail(f"provenance reports reuse artifact path: {relative}")
        paths.add(relative)
        sha256_string(descriptor["sha256"], f"provenance.reports.{role}.sha256")
    normalized = dict(provenance)
    normalized["sources"] = sources
    return normalized


def nearest_rank(values, percentile: int) -> int:
    ordered = sorted(values)
    index = math.ceil(percentile * len(ordered) / 100) - 1
    return ordered[index]


def statistics(values):
    if not values:
        fail("cannot summarize an empty sample set")
    return {
        "sampleCount": len(values),
        "minimumFs": min(values),
        "maximumFs": max(values),
        "sumFs": sum(values),
        "p50Fs": nearest_rank(values, 50),
        "p99Fs": nearest_rank(values, 99),
    }


def parse_latency_report(path: Path):
    document = load_json(path)
    report = exact_object(
        document,
        (
            "schemaVersion",
            "api",
            "boundaryDefinition",
            "traceId",
            "unit",
            "samples",
        ),
        "latency report",
    )
    if report["schemaVersion"] != 1 or report["api"] != LATENCY_API:
        fail("unsupported latency report API")
    if report["boundaryDefinition"] != BOUNDARY_DEFINITION:
        fail("unsupported latency boundary definition")
    sha256_string(report["traceId"], "latency report traceId")
    if report["unit"] != "fs":
        fail("latency report unit must be fs")
    if not isinstance(report["samples"], list) or not report["samples"]:
        fail("latency report samples must be a non-empty array")
    sample_keys = []
    seen_ids = set()
    boundary_values = {name: [] for name in BOUNDARIES}
    component_values = {name: [] for name in COMPONENT_BOUNDARIES}
    total_values = []
    for index, item in enumerate(report["samples"]):
        field = f"latency report samples[{index}]"
        sample = exact_object(
            item, ("sampleId", "requestSha256", "boundariesFs"), field
        )
        sample_id = nonempty_string(sample["sampleId"], f"{field}.sampleId")
        if sample_id in seen_ids:
            fail(f"duplicate latency sample ID: {sample_id}")
        seen_ids.add(sample_id)
        request_sha256 = sha256_string(
            sample["requestSha256"], f"{field}.requestSha256"
        )
        boundaries = exact_object(
            sample["boundariesFs"], BOUNDARIES, f"{field}.boundariesFs"
        )
        timestamps = []
        for name in BOUNDARIES:
            timestamps.append(
                nonnegative_integer(
                    boundaries[name], f"{field}.boundariesFs.{name}", MAX_TIME_FS
                )
            )
        if timestamps != sorted(timestamps):
            fail(f"{field} boundary timestamps are not monotonic")
        start = boundaries["inputComplete"]
        for name in BOUNDARIES:
            boundary_values[name].append(boundaries[name] - start)
        for name, (component_start, component_end) in COMPONENT_BOUNDARIES.items():
            component_values[name].append(
                boundaries[component_end] - boundaries[component_start]
            )
        total_values.append(boundaries["outputComplete"] - start)
        sample_keys.append({"sampleId": sample_id, "requestSha256": request_sha256})
    for index in range(len(total_values)):
        component_sum = sum(component_values[name][index] for name in component_values)
        if component_sum != total_values[index]:
            fail("latency component durations do not sum to total latency")
    sample_set_id = hashlib.sha256(canonical(sample_keys)).hexdigest()
    return {
        "summary": {
            "boundaryDefinition": report["boundaryDefinition"],
            "traceId": report["traceId"],
            "sampleSetId": sample_set_id,
            "sampleCount": len(sample_keys),
            "boundaries": {
                name: statistics(boundary_values[name]) for name in BOUNDARIES
            },
            "components": {
                name: statistics(component_values[name])
                for name in COMPONENT_BOUNDARIES
            },
            "total": statistics(total_values),
        },
        "sampleKeys": sample_keys,
        "durations": {
            "components": component_values,
            "total": total_values,
        },
    }


def parts_per_million(numerator: int, denominator: int) -> int:
    if denominator <= 0:
        fail("relative metric denominator must be positive")
    scaled = numerator * 1_000_000
    if scaled >= 0:
        return (2 * scaled + denominator) // (2 * denominator)
    return -((2 * -scaled + denominator) // (2 * denominator))


def utilization_output(parsed):
    output = {}
    for name, resource in parsed["resources"].items():
        output[name] = {
            "used": resource["used"],
            "available": resource["available"],
            "unit": resource["unit"],
            "devicePartsPerMillion": parts_per_million(
                resource["used"], resource["available"]
            ),
        }
    return output


def load_record(request_entry, role: str, deployment: str):
    exact_object(request_entry, ("packageRoot", "provenance"), f"request.{role}")
    raw_root = nonempty_string(
        request_entry["packageRoot"], f"request.{role}.packageRoot"
    )
    root = Path(raw_root)
    if not root.is_absolute():
        fail(f"request.{role}.packageRoot must be absolute")
    try:
        root = root.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve request.{role}.packageRoot: {error}")
    if not root.is_dir():
        fail(f"request.{role}.packageRoot is not a directory")
    provenance_path, provenance_artifact = resolve_hashed_artifact(
        root, request_entry["provenance"], f"request.{role}.provenance"
    )
    provenance = validate_provenance(load_json(provenance_path), deployment)
    report_paths = {}
    report_artifacts = {}
    for report_role in ("timing", "latency", "utilization"):
        report_path, artifact = resolve_hashed_artifact(
            root,
            provenance["reports"][report_role],
            f"{role} {report_role} report",
        )
        report_paths[report_role] = report_path
        report_artifacts[report_role] = artifact
    timing = parse_timing_report(report_paths["timing"])
    utilization = parse_utilization_report(report_paths["utilization"])
    latency = parse_latency_report(report_paths["latency"])
    build = provenance["build"]
    definition = provenance["definition"]
    expected_version = build["tool"]["version"]
    if timing["toolVersion"] != expected_version:
        fail(f"{role} timing report tool version does not match provenance")
    if utilization["toolVersion"] != expected_version:
        fail(f"{role} utilization report tool version does not match provenance")
    expected_part = definition["board"]["part"]
    if not device_matches(expected_part, timing["device"]):
        fail(f"{role} timing report device does not match provenance")
    if not device_matches(expected_part, utilization["device"]):
        fail(f"{role} utilization report device does not match provenance")
    if not device_matches(timing["device"], utilization["device"]):
        fail(f"{role} timing and utilization reports name different devices")
    normalized_timing = dict(timing)
    normalized_timing["tool"] = dict(build["tool"])
    normalized_timing.pop("toolVersion")
    record = {
        "role": role,
        "deployment": deployment,
        "package": {
            "name": provenance["packageName"],
            "root": str(root),
        },
        "definition": definition,
        "timing": normalized_timing,
        "latency": latency["summary"],
        "utilization": utilization_output(utilization),
        "provenance": {
            "manifest": provenance_artifact,
            "build": build,
            "sources": provenance["sources"],
            "reports": report_artifacts,
        },
    }
    record["recordId"] = hashlib.sha256(canonical(record)).hexdigest()
    return record, latency["sampleKeys"], latency["durations"]


def paired_deltas(baseline, qshell, field: str):
    if len(baseline) != len(qshell):
        fail(f"latency {field} sample count mismatch")
    return [candidate - reference for reference, candidate in zip(baseline, qshell)]


def latency_overhead(baseline, qshell, baseline_durations, qshell_durations):
    baseline_total = baseline_durations["total"]
    qshell_total = qshell_durations["total"]
    baseline_total_sum = sum(baseline_total)
    qshell_total_sum = sum(qshell_total)
    total = {
        "baseline": statistics(baseline_total),
        "qshell": statistics(qshell_total),
        "delta": statistics(paired_deltas(baseline_total, qshell_total, "total")),
        "relativePartsPerMillion": parts_per_million(
            qshell_total_sum - baseline_total_sum, baseline_total_sum
        ),
    }
    components = {}
    for name in COMPONENT_BOUNDARIES:
        baseline_values = baseline_durations["components"][name]
        qshell_values = qshell_durations["components"][name]
        baseline_sum = sum(baseline_values)
        qshell_sum = sum(qshell_values)
        components[name] = {
            "baseline": statistics(baseline_values),
            "qshell": statistics(qshell_values),
            "delta": statistics(paired_deltas(baseline_values, qshell_values, name)),
            "qshellContributionPartsPerMillion": parts_per_million(
                qshell_sum, baseline_total_sum
            ),
            "deltaContributionPartsPerMillion": parts_per_million(
                qshell_sum - baseline_sum, baseline_total_sum
            ),
        }
    return {"total": total, "components": components}


def utilization_overhead(baseline, qshell):
    result = {}
    for name in ("lut", "register", "bramTiles", "uram", "dsp"):
        base_resource = baseline["utilization"][name]
        qshell_resource = qshell["utilization"][name]
        if base_resource["unit"] != qshell_resource["unit"]:
            fail(f"utilization unit mismatch: {name}")
        if base_resource["available"] != qshell_resource["available"]:
            fail(f"utilization device capacity mismatch: {name}")
        base_used = base_resource["used"]
        qshell_used = qshell_resource["used"]
        if base_used == 0:
            relative = {"state": "unavailable", "reason": "zero-baseline"}
        else:
            relative = {
                "state": "available",
                "partsPerMillion": parts_per_million(
                    qshell_used - base_used, base_used
                ),
            }
        result[name] = {
            "unit": base_resource["unit"],
            "available": base_resource["available"],
            "baselineUsed": base_used,
            "qshellUsed": qshell_used,
            "delta": qshell_used - base_used,
            "deviceDeltaPartsPerMillion": parts_per_million(
                qshell_used - base_used, base_resource["available"]
            ),
            "relative": relative,
        }
    return result


def compare(request_path: Path):
    request = exact_object(
        load_json(request_path),
        ("schemaVersion", "api", "baseline", "qshell"),
        "request",
    )
    if request["schemaVersion"] != 1 or request["api"] != REQUEST_API:
        fail("unsupported matched implementation request API")
    baseline, baseline_samples, baseline_durations = load_record(
        request["baseline"], "baseline", "standalone-coyote"
    )
    qshell, qshell_samples, qshell_durations = load_record(
        request["qshell"], "qshell", "qshell"
    )
    for field in MATCH_FIELDS:
        if baseline["definition"][field] != qshell["definition"][field]:
            fail(f"comparison definition mismatch: {field}")
    if (
        baseline["provenance"]["build"]["strategyId"]
        != qshell["provenance"]["build"]["strategyId"]
    ):
        fail("comparison build strategy mismatch")
    if baseline["provenance"]["build"]["tool"] != qshell["provenance"]["build"]["tool"]:
        fail("comparison build tool mismatch")
    for role, record in (("baseline", baseline), ("qshell", qshell)):
        if record["provenance"]["build"]["outcome"] != "accepted":
            fail(f"{role} implementation outcome is not accepted")
        if not record["timing"]["met"]:
            fail(f"{role} implementation does not meet timing")
        state = record["timing"]["designState"].lower().replace(" ", "")
        if state not in ("routed", "postroute"):
            fail(f"{role} timing report is not from a routed design")
    if (
        baseline["latency"]["boundaryDefinition"]
        != qshell["latency"]["boundaryDefinition"]
    ):
        fail("comparison latency boundary definition mismatch")
    if baseline["latency"]["traceId"] != qshell["latency"]["traceId"]:
        fail("comparison latency trace mismatch")
    if baseline_samples != qshell_samples:
        fail("comparison latency sample/request set mismatch")
    if baseline["latency"]["sampleSetId"] != qshell["latency"]["sampleSetId"]:
        fail("comparison latency sample-set identity mismatch")
    if baseline["latency"]["total"]["sumFs"] <= 0:
        fail("baseline total latency must be positive before computing overhead")
    controls = {
        "buildStrategyId": baseline["provenance"]["build"]["strategyId"],
        "tool": baseline["provenance"]["build"]["tool"],
        "traceId": baseline["latency"]["traceId"],
        "sampleSetId": baseline["latency"]["sampleSetId"],
    }
    output = {
        "schemaVersion": 1,
        "api": OUTPUT_API,
        "kind": OUTPUT_KIND,
        "match": baseline["definition"],
        "controls": controls,
        "records": {"baseline": baseline, "qshell": qshell},
        "overhead": {
            "latency": latency_overhead(
                baseline, qshell, baseline_durations, qshell_durations
            ),
            "utilization": utilization_overhead(baseline, qshell),
        },
    }
    output["comparisonId"] = hashlib.sha256(canonical(output)).hexdigest()
    return output


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Extract and compare immutable standalone-Coyote and QShell "
            "implementation evidence"
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    compare_parser = subparsers.add_parser(
        "compare", help="validate a matched request and emit normalized evidence"
    )
    compare_parser.add_argument("request", type=Path)
    compare_parser.add_argument("--output", "-o", type=Path)
    args = parser.parse_args()
    try:
        document = compare(args.request)
        encoded = canonical(document)
        if args.output is None:
            sys.stdout.buffer.write(encoded)
        else:
            atomic_write(args.output, encoded)
    except EvidenceError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
