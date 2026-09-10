#!/usr/bin/env python3
"""Collect and verify fail-closed Coyote physical-signoff evidence."""

import argparse
from decimal import Decimal, InvalidOperation
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tempfile

EVIDENCE_API = "coyote-nix.strict-signoff-evidence/v1"
ENDPOINT_EVIDENCE_API = "coyote-nix.strict-signoff-endpoints/v1"
CLASSIFICATION_API = "coyote-nix.strict-signoff-classification/v1"
RESULT_API = "coyote-nix.strict-signoff-result/v1"
PHASES = ("link", "place", "route", "validate")
CHECKPOINT_ROLES = {
    "link": "linked-checkpoint",
    "place": "placed-checkpoint",
    "route": "routed-checkpoint",
    "validate": "validated-checkpoint",
}
REPORT_KINDS = {
    "methodology": "methodology",
    "timingExceptions": "timing_exceptions",
    "busSkew": "bus_skew",
    "clockInteraction": "clock_interaction",
    "unconstrainedEndpoints": "unconstrained_endpoints",
    "implementationDrc": "drc",
    "timingSummary": "timing_summary",
}
REPORT_SIGNATURES = {
    "methodology": re.compile(r"report_methodology|report methodology", re.IGNORECASE),
    "timingExceptions": re.compile(
        r"report_exceptions|report exceptions|timing exceptions", re.IGNORECASE
    ),
    "busSkew": re.compile(r"report_bus_skew|bus skew", re.IGNORECASE),
    "clockInteraction": re.compile(
        r"report_clock_interaction|clock interaction", re.IGNORECASE
    ),
    "unconstrainedEndpoints": re.compile(r"check_timing report", re.IGNORECASE),
    "implementationDrc": re.compile(r"report_drc|report drc", re.IGNORECASE),
    "bitstreamDrc": re.compile(r"report_drc|report drc", re.IGNORECASE),
    "timingSummary": re.compile(
        r"report_timing_summary|timing summary report", re.IGNORECASE
    ),
    "routeStatus": re.compile(
        r"report_route_status|design route status", re.IGNORECASE
    ),
}
REQUIRED_VALIDATE_ROLES = {
    "methodology": "validate-methodology-report",
    "timingExceptions": "validate-timing-exception-report",
    "busSkew": "validate-bus-skew-report",
    "clockInteraction": "validate-clock-interaction-report",
    "unconstrainedEndpoints": "validate-unconstrained-endpoint-report",
    "endpointEvidence": "validate-unconstrained-endpoint-evidence",
    "implementationDrc": "validate-drc-report",
    "timingSummary": "validate-timing-summary-report",
    "routeStatus": "validate-route-status-report",
    "bitstreamDrc": "bitstream-drc-report",
}


class ContractError(ValueError):
    def __init__(self, category: str, message: str):
        super().__init__(message)
        self.category = category


def fail(category: str, message: str) -> None:
    raise ContractError(category, message)


def strict_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def reject_json_constant(value):
    raise ValueError(f"non-finite JSON value: {value}")


def load_json(path: Path, category: str):
    try:
        with path.open("r", encoding="utf-8") as stream:
            return json.load(
                stream,
                object_pairs_hook=strict_object,
                parse_constant=reject_json_constant,
            )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        fail(category, f"cannot read JSON {path}: {error}")


def canonical(value) -> bytes:
    return (
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        )
        + "\n"
    ).encode()


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


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        fail("reports", f"cannot hash report {path}: {error}")
    return digest.hexdigest()


def safe_relative(raw: str, category: str = "reports") -> PurePosixPath:
    if not isinstance(raw, str) or not raw:
        fail(category, "artifact path must be a non-empty string")
    path = PurePosixPath(raw)
    if (
        path.is_absolute()
        or ".." in path.parts
        or "." in path.parts
        or str(path) != raw
    ):
        fail(category, f"unsafe or non-canonical artifact path: {raw}")
    return path


def resolve_contained(root: Path, raw: str, category: str = "reports") -> Path:
    relative = safe_relative(raw, category)
    try:
        root_real = root.resolve(strict=True)
        path = root.joinpath(*relative.parts).resolve(strict=True)
        path.relative_to(root_real)
    except (OSError, ValueError) as error:
        fail(category, f"missing or escaping artifact {relative}: {error}")
    if not path.is_file():
        fail(category, f"artifact is not a regular file: {relative}")
    return path


def report_text(path: Path, kind: str) -> str:
    try:
        data = path.read_bytes()
    except OSError as error:
        fail("reports", f"cannot read {kind} report {path}: {error}")
    if not data or b"\x00" in data:
        fail("reports", f"{kind} report is empty or non-textual: {path}")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        fail("reports", f"{kind} report is not UTF-8 text: {error}")
    if REPORT_SIGNATURES[kind].search(text) is None:
        fail("reports", f"malformed {kind} report: expected report signature is absent")
    return text


def decimal_value(value, field: str, category: str = "timing") -> Decimal:
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        fail(category, f"{field} must be a finite decimal number")
    try:
        result = Decimal(str(value))
    except InvalidOperation:
        fail(category, f"{field} must be a finite decimal number")
    if not result.is_finite():
        fail(category, f"{field} must be a finite decimal number")
    return result


def canonical_decimal(value: str, field: str) -> str:
    decimal = decimal_value(value, field, "reports")
    result = format(decimal, "f")
    if decimal == 0 and result.startswith("-"):
        result = result[1:]
    return result


def parse_timing_summary(text: str):
    lines = text.splitlines()
    section_indices = [
        index
        for index, line in enumerate(lines)
        if line.strip() == "| Design Timing Summary"
    ]
    if len(section_indices) != 1:
        fail(
            "reports",
            "timing summary must contain exactly one Design Timing Summary section",
        )
    section_start = section_indices[0]
    section_end = next(
        (
            index
            for index in range(section_start + 1, len(lines))
            if lines[index].strip() == "| Clock Summary"
        ),
        len(lines),
    )
    header_indices = [
        index
        for index in range(section_start, section_end)
        if all(
            field in lines[index]
            for field in ("WNS(ns)", "TNS(ns)", "WHS(ns)", "THS(ns)")
        )
    ]
    if len(header_indices) != 1:
        fail("reports", "timing summary must contain one overall setup/hold table")
    for line in lines[header_indices[0] + 1 : section_end]:
        stripped = line.strip()
        if not stripped or set(stripped) <= {"-", " "}:
            continue
        fields = stripped.split()
        if len(fields) < 8:
            continue
        try:
            return {
                "setupWnsNs": canonical_decimal(fields[0], "WNS"),
                "setupTnsNs": canonical_decimal(fields[1], "TNS"),
                "holdWnsNs": canonical_decimal(fields[4], "WHS"),
                "holdTnsNs": canonical_decimal(fields[5], "THS"),
            }
        except ContractError:
            continue
    fail("reports", "timing summary has no numeric overall setup/hold row")


def parse_route_status(text: str):
    def count(label: str) -> int:
        matches = re.findall(
            rf"# of {label}[^:]*:\s*([0-9][0-9,]*)\s*:", text, re.IGNORECASE
        )
        if len(matches) != 1:
            fail("reports", f"route status requires exactly one {label} count")
        return int(matches[0].replace(",", ""))

    return {
        "routableNets": count("routable nets"),
        "fullyRoutedNets": count("fully routed nets"),
        "netsWithRoutingErrors": count("nets with routing errors"),
    }


def parse_drc(text: str, kind: str):
    summary_matches = re.findall(
        r"^\s*(Checks|Violations) found:\s*([0-9][0-9,]*)\s*$",
        text,
        re.IGNORECASE | re.MULTILINE,
    )
    if len(summary_matches) != 1:
        fail("reports", f"{kind} report requires exactly one supported DRC summary count")
    summary_label, raw_summary_count = summary_matches[0]
    count_column = "Checks" if summary_label.lower() == "checks" else "Violations"
    checks_found = int(raw_summary_count.replace(",", ""))

    lines = text.splitlines()
    table_headers = []
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.startswith("|") or not stripped.endswith("|"):
            continue
        cells = [cell.strip() for cell in stripped[1:-1].split("|")]
        lowered = [cell.lower() for cell in cells]
        if all(field in lowered for field in ("rule", "severity", "description")):
            table_headers.append((index, cells, lowered))
    if len(table_headers) != 1:
        fail("reports", f"{kind} report requires exactly one DRC summary table")
    header_index, header_cells, header_lowered = table_headers[0]
    if count_column.lower() not in header_lowered:
        fail("reports", f"{kind} report summary count label does not match its table")
    severity_index = header_lowered.index("severity")
    count_index = header_lowered.index(count_column.lower())
    if count_index != len(header_cells) - 1:
        fail("reports", f"{kind} report DRC count column must be the final table column")

    severity_counts = {}
    saw_table_boundary = False
    for line in lines[header_index + 1 :]:
        stripped = line.strip()
        if not stripped:
            if saw_table_boundary:
                break
            continue
        if stripped.startswith("+") and stripped.endswith("+"):
            saw_table_boundary = True
            continue
        if not stripped.startswith("|") or not stripped.endswith("|"):
            if saw_table_boundary:
                break
            continue
        cells = [cell.strip() for cell in stripped[1:-1].split("|")]
        if len(cells) != len(header_cells):
            fail("reports", f"{kind} report contains a malformed DRC table row")
        lowered = [cell.lower() for cell in cells]
        if all(field in lowered for field in ("rule", "severity", "description")):
            fail("reports", f"{kind} report contains multiple DRC summary table headers")
        severity = cells[severity_index]
        if severity not in ("Error", "Critical Warning", "Warning", "Advisory"):
            fail("reports", f"{kind} report contains an unknown DRC severity: {severity}")
        raw_count = cells[count_index].replace(",", "")
        if not raw_count.isdigit():
            fail("reports", f"{kind} report contains a malformed DRC count")
        severity_counts[severity] = severity_counts.get(severity, 0) + int(raw_count)
    if sum(severity_counts.values()) != checks_found:
        noun = "check" if count_column == "Checks" else "violation"
        fail("reports", f"{kind} report summary does not account for every DRC {noun}")
    return {
        "checks": checks_found,
        "errors": severity_counts.get("Error", 0),
        "criticalWarnings": severity_counts.get("Critical Warning", 0),
        "warnings": severity_counts.get("Warning", 0),
    }


def endpoint_reason(category: str, description: str) -> str:
    lowered = description.lower()
    if category == "no_clock":
        return "no-clock"
    if "due to constant clock" in lowered:
        return "constant-clock"
    if "not constrained for maximum delay" in lowered:
        return "missing-max-delay"
    fail("reports", f"unrecognized {category} endpoint group: {description}")


def parse_endpoint_section(lines, category: str):
    header = re.compile(rf"^\d+\.\s+checking\s+{re.escape(category)}\s+\((\d+)\)\s*$")
    matches = [(index, header.match(line.strip())) for index, line in enumerate(lines)]
    matches = [(index, match) for index, match in matches if match is not None]
    if not matches:
        fail("reports", f"check_timing report omits {category}")
    start, match = matches[-1]
    expected_count = int(match.group(1))
    next_section = re.compile(r"^\d+\.\s+checking\s+[a-z0-9_]+\s+\(\d+\)\s*$")
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if next_section.match(lines[index].strip()):
            end = index
            break
    current_description = ""
    entries = []
    for raw_line in lines[start + 1 : end]:
        stripped = raw_line.strip()
        if stripped.lower().startswith("there are "):
            current_description = stripped
            continue
        if (
            stripped
            and raw_line == raw_line.lstrip()
            and "/" in stripped
            and not stripped.startswith("-")
        ):
            reason = endpoint_reason(category, current_description)
            entries.append(
                {"category": category, "endpoint": stripped, "reason": reason}
            )
    if len(entries) != expected_count:
        fail(
            "reports",
            f"check_timing {category} declares {expected_count} endpoints but lists {len(entries)}",
        )
    return entries


def parse_unconstrained_endpoints(text: str):
    lines = text.splitlines()
    entries = parse_endpoint_section(lines, "no_clock") + parse_endpoint_section(
        lines, "unconstrained_internal_endpoints"
    )
    keys = [(entry["category"], entry["endpoint"]) for entry in entries]
    if len(keys) != len(set(keys)):
        fail(
            "reports", "check_timing report contains duplicate unconstrained endpoints"
        )
    return sorted(
        entries,
        key=lambda entry: (entry["category"], entry["endpoint"], entry["reason"]),
    )


def parse_endpoint_evidence(path: Path, report_entries):
    document = load_json(path, "reports")
    require_exact_keys(
        document,
        ("schemaVersion", "api", "endpoints"),
        "reports",
        "unconstrained endpoint evidence",
    )
    if document["schemaVersion"] != 1 or document["api"] != ENDPOINT_EVIDENCE_API:
        fail("reports", "unsupported unconstrained endpoint evidence API")
    entries = document["endpoints"]
    if not isinstance(entries, list):
        fail("reports", "unconstrained endpoint evidence endpoints must be an array")

    normalized = []
    for entry in entries:
        require_exact_keys(
            entry,
            ("category", "endpoint", "reason", "clockPins"),
            "reports",
            "unconstrained endpoint evidence entry",
        )
        if entry["category"] not in ("no_clock", "unconstrained_internal_endpoints"):
            fail("reports", "unconstrained endpoint evidence has an invalid category")
        if not isinstance(entry["endpoint"], str) or not entry["endpoint"]:
            fail("reports", "unconstrained endpoint evidence has an invalid endpoint")
        if entry["reason"] not in ("no-clock", "constant-clock", "missing-max-delay"):
            fail("reports", "unconstrained endpoint evidence has an invalid reason")
        clock_pins = entry["clockPins"]
        if not isinstance(clock_pins, list):
            fail("reports", "unconstrained endpoint clockPins must be an array")
        normalized_clock_pins = []
        for clock_pin in clock_pins:
            require_exact_keys(
                clock_pin,
                ("pin", "constantValue", "clocks"),
                "reports",
                "unconstrained endpoint clock pin",
            )
            if not isinstance(clock_pin["pin"], str) or not clock_pin["pin"]:
                fail("reports", "unconstrained endpoint clock pin name is invalid")
            if not isinstance(clock_pin["constantValue"], str):
                fail("reports", "unconstrained endpoint constantValue must be a string")
            clocks = clock_pin["clocks"]
            if (
                not isinstance(clocks, list)
                or any(not isinstance(clock, str) or not clock for clock in clocks)
                or clocks != sorted(set(clocks))
            ):
                fail(
                    "reports", "unconstrained endpoint clocks must be sorted and unique"
                )
            normalized_clock_pins.append(
                {
                    "pin": clock_pin["pin"],
                    "constantValue": clock_pin["constantValue"],
                    "clocks": clocks,
                }
            )
        if normalized_clock_pins != sorted(
            normalized_clock_pins, key=lambda clock_pin: clock_pin["pin"]
        ) or len({clock_pin["pin"] for clock_pin in normalized_clock_pins}) != len(
            normalized_clock_pins
        ):
            fail(
                "reports", "unconstrained endpoint clock pins must be sorted and unique"
            )
        normalized.append(
            {
                "category": entry["category"],
                "endpoint": entry["endpoint"],
                "reason": entry["reason"],
                "clockPins": normalized_clock_pins,
            }
        )

    normalized = sorted(
        normalized,
        key=lambda entry: (entry["category"], entry["endpoint"], entry["reason"]),
    )
    keys = [(entry["category"], entry["endpoint"]) for entry in normalized]
    if len(keys) != len(set(keys)):
        fail("reports", "unconstrained endpoint evidence contains duplicate endpoints")
    report_core = [
        {
            "category": entry["category"],
            "endpoint": entry["endpoint"],
            "reason": entry["reason"],
        }
        for entry in normalized
    ]
    if report_core != report_entries:
        fail(
            "reports", "endpoint/clock evidence does not match the check_timing report"
        )
    for entry in normalized:
        entry["id"] = hashlib.sha256(canonical(entry)).hexdigest()
    return normalized


def file_descriptor(root: Path, path: Path):
    try:
        relative = path.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (OSError, ValueError) as error:
        fail("reports", f"artifact is outside evidence root: {error}")
    if not path.is_file():
        fail("reports", f"evidence artifact is not a regular file: {path}")
    return {
        "path": PurePosixPath(relative).as_posix(),
        "sha256": sha256_file(path),
        "size": path.stat().st_size,
    }


def source_identity(context):
    result = {
        "contextId": context.get("id"),
        "flow": context.get("flow"),
        "sourceId": context.get("sourceId"),
        "coyoteSourceId": context.get("coyoteSourceId"),
        "constraintsId": context.get("constraintsId"),
    }
    if any(not isinstance(value, str) or not value for value in result.values()):
        fail("reports", "strict-signoff context is missing immutable source identity")
    if re.fullmatch(r"[0-9a-f]{64}", result["contextId"]) is None:
        fail("reports", "strict-signoff context ID must be a SHA-256 value")
    return result


def build_evidence(
    root: Path, phase: str, unit: str, context, checkpoint: Path, report_paths
):
    if phase not in PHASES:
        fail("reports", f"unsupported strict-signoff phase: {phase}")
    if not isinstance(unit, str) or not unit:
        fail("reports", "strict-signoff unit must be non-empty")
    identity = source_identity(context)

    texts = {}
    descriptors = {}
    expected_keys = set(REPORT_KINDS) | {"endpointEvidence"}
    if phase in ("route", "validate"):
        expected_keys.add("routeStatus")
    if phase == "validate":
        expected_keys.add("bitstreamDrc")
    if set(report_paths) != expected_keys:
        fail("reports", "strict-signoff report set does not match phase applicability")
    for kind in sorted(report_paths):
        path = report_paths[kind]
        if kind != "endpointEvidence":
            texts[kind] = report_text(path, kind)
        descriptors[kind] = file_descriptor(root, path)

    timing = parse_timing_summary(texts["timingSummary"])
    report_endpoints = parse_unconstrained_endpoints(texts["unconstrainedEndpoints"])
    endpoints = parse_endpoint_evidence(
        report_paths["endpointEvidence"], report_endpoints
    )
    implementation_drc = parse_drc(texts["implementationDrc"], "implementation DRC")
    route = parse_route_status(texts["routeStatus"]) if "routeStatus" in texts else None
    bitstream_drc = (
        parse_drc(texts["bitstreamDrc"], "bitstream DRC")
        if "bitstreamDrc" in texts
        else None
    )
    evidence = {
        "schemaVersion": 1,
        "api": EVIDENCE_API,
        "phase": phase,
        "unit": unit,
        "sourceIdentity": identity,
        "artifactIdentity": {
            "role": CHECKPOINT_ROLES[phase],
            **file_descriptor(root, checkpoint),
        },
        "reports": descriptors,
        "timing": timing,
        "routing": route,
        "drc": {
            "implementation": implementation_drc,
            "bitstream": bitstream_drc,
        },
        "timingExceptionSet": {
            "reportSha256": descriptors["timingExceptions"]["sha256"],
        },
        "unconstrainedEndpoints": endpoints,
    }
    evidence["evidenceId"] = hashlib.sha256(canonical(evidence)).hexdigest()
    return evidence


def validate_context(context_path: Path):
    context = load_json(context_path, "reports")
    if not isinstance(context, dict):
        fail("reports", "implementation context must be an object")
    without_id = dict(context)
    context_id = without_id.pop("id", None)
    if context_id != hashlib.sha256(canonical(without_id).rstrip(b"\n")).hexdigest():
        fail(
            "reports", "implementation context ID does not match its canonical content"
        )
    return context


def collect(args):
    root = args.root.resolve(strict=True)
    context = validate_context(args.context)
    report_directory = safe_relative(args.report_directory)
    directory = root.joinpath(*report_directory.parts)
    report_paths = {
        kind: directory / f"{args.report_prefix}_{name}{args.report_suffix}.rpt"
        for kind, name in REPORT_KINDS.items()
    }
    report_paths["endpointEvidence"] = (
        directory
        / f"{args.report_prefix}_unconstrained_endpoint_evidence{args.report_suffix}.json"
    )
    if args.phase in ("route", "validate"):
        report_paths["routeStatus"] = (
            directory / f"{args.report_prefix}_route_status{args.report_suffix}.rpt"
        )
    if args.phase == "validate":
        report_paths["bitstreamDrc"] = (
            directory
            / f"{args.report_prefix}_drc_bitstream_checks{args.report_suffix}.rpt"
        )
    evidence = build_evidence(
        root, args.phase, args.unit, context, args.checkpoint, report_paths
    )
    atomic_write(args.output, canonical(evidence))


def manifest_artifacts(stage: Path, manifest):
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list):
        fail("stage", "stage manifest artifacts must be an array")
    result = {}
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            fail("stage", "stage manifest artifact must be an object")
        role = artifact.get("role")
        if not isinstance(role, str) or not role or role in result:
            fail("stage", f"invalid or duplicate stage artifact role: {role}")
        if set(artifact) != {"role", "path", "sha256", "size"}:
            fail("stage", f"stage artifact {role} has malformed fields")
        path = resolve_contained(stage, artifact["path"], "stage")
        if (
            artifact["sha256"] != sha256_file(path)
            or artifact["size"] != path.stat().st_size
        ):
            fail("stage", f"stage artifact integrity mismatch: {role}")
        result[role] = (artifact, path)
    return result


def require_exact_keys(value, expected, category: str, label: str):
    if not isinstance(value, dict) or set(value) != set(expected):
        fail(category, f"{label} requires exactly: {', '.join(sorted(expected))}")


def validate_manifest_identity(stage: Path, manifest):
    if not isinstance(manifest, dict):
        fail("stage", "stage manifest must be an object")
    stage_apis = {
        1: "coyote-nix.implementation-stage/v1",
        2: "coyote-nix.implementation-stage/v2",
    }
    if manifest.get("api") != stage_apis.get(manifest.get("schemaVersion")):
        fail("stage", "unsupported implementation-stage manifest API")
    without_id = dict(manifest)
    manifest_id = without_id.pop("manifestId", None)
    if (
        not isinstance(manifest_id, str)
        or re.fullmatch(r"[0-9a-f]{64}", manifest_id) is None
        or manifest_id != hashlib.sha256(canonical(without_id)).hexdigest()
    ):
        fail("stage", "stage manifest identity is stale or malformed")
    try:
        complete_id = (
            (stage / "metadata" / "complete").read_text(encoding="utf-8").strip()
        )
    except OSError as error:
        fail("stage", f"cannot read stage completion identity: {error}")
    if complete_id != manifest_id:
        fail("stage", "stage completion identity does not match the manifest")
    context = manifest.get("context")
    if not isinstance(context, dict):
        fail("stage", "stage manifest context must be an object")
    context_without_id = dict(context)
    context_id = context_without_id.pop("id", None)
    if (
        context_id
        != hashlib.sha256(canonical(context_without_id).rstrip(b"\n")).hexdigest()
    ):
        fail("stage", "stage context identity is stale or malformed")
    return manifest_id


def validate_physical(physical, evidence):
    if not isinstance(physical, dict):
        fail("timing", "physical observations must be an object")
    if (
        physical.get("schemaVersion") != 1
        or physical.get("kind") != "coyote-implementation-observations"
    ):
        fail("timing", "unsupported physical observation evidence")
    if physical.get("phase") != "validate" or physical.get("analysisKind") != "routed":
        fail("timing", "strict signoff requires routed validation observations")

    raw_timing = evidence["timing"]
    physical_timing = physical.get("timing")
    require_exact_keys(
        physical_timing,
        ("setupWnsNs", "setupTnsNs", "holdWnsNs", "holdTnsNs"),
        "timing",
        "physical timing",
    )
    for key in ("setupWnsNs", "setupTnsNs", "holdWnsNs", "holdTnsNs"):
        observed = decimal_value(physical_timing[key], key)
        reported = decimal_value(raw_timing[key], key)
        if observed != reported:
            fail("timing", f"physical {key} does not match the timing summary")
        if observed < 0:
            fail("timing", f"strict signoff rejects negative {key}: {observed}")

    physical_routing = physical.get("routing")
    require_exact_keys(
        physical_routing,
        ("unroutedNets", "partiallyRoutedNets", "conflictedNets", "hasRoutingErrors"),
        "routing",
        "physical routing",
    )
    for key in (
        "unroutedNets",
        "partiallyRoutedNets",
        "conflictedNets",
        "hasRoutingErrors",
    ):
        value = physical_routing[key]
        if isinstance(value, bool) or not isinstance(value, int):
            fail("routing", f"physical {key} must be an integer")
        if value != 0:
            fail("routing", f"strict signoff rejects nonzero {key}: {value}")
    route = evidence["routing"]
    if route["routableNets"] != route["fullyRoutedNets"]:
        fail("routing", "route-status report is not fully routed")
    if route["netsWithRoutingErrors"] != 0:
        fail("routing", "route-status report contains routing errors")

    physical_drc = physical.get("drc")
    require_exact_keys(
        physical_drc,
        ("errors", "criticalWarnings", "warnings"),
        "drc",
        "physical DRC",
    )
    for key in ("errors", "criticalWarnings", "warnings"):
        value = physical_drc[key]
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            fail("drc", f"physical DRC {key} must be a non-negative integer")
    bitstream = evidence["drc"]["bitstream"]
    for key in ("errors", "criticalWarnings", "warnings"):
        if physical_drc[key] != bitstream[key]:
            fail("drc", f"physical DRC {key} does not match bitstream DRC report")
    for name, result in evidence["drc"].items():
        if result["errors"] != 0 or result["criticalWarnings"] != 0:
            fail(
                "drc", f"strict signoff rejects {name} DRC errors or critical warnings"
            )


def validate_classification(path: Path, manifest, evidence):
    context = manifest["context"]
    unit = manifest["unit"]
    classification = load_json(path, "classification")
    require_exact_keys(
        classification,
        ("schemaVersion", "api", "contextId", "subjects"),
        "classification",
        "strict-signoff classification",
    )
    if (
        classification["schemaVersion"] != 1
        or classification["api"] != CLASSIFICATION_API
    ):
        fail("classification", "unsupported strict-signoff classification API")
    if classification["contextId"] != context["id"]:
        fail("classification", "classification context is stale or mismatched")
    subjects = classification["subjects"]
    if not isinstance(subjects, list) or not subjects:
        fail("classification", "classification subjects must be a non-empty array")
    matching = []
    units = []
    for subject in subjects:
        require_exact_keys(
            subject,
            (
                "unit",
                "evidenceId",
                "stageManifestId",
                "artifactIdentity",
                "sourceIdentity",
                "timingExceptionReport",
                "unconstrainedEndpoints",
            ),
            "classification",
            "classification subject",
        )
        if subject["unit"] == unit:
            units.append(subject)
            if subject["evidenceId"] == evidence["evidenceId"]:
                matching.append(subject)
    if len(matching) != 1:
        if units:
            fail(
                "classification",
                "classification evidence identity is stale or mismatched",
            )
        fail(
            "classification",
            f"classification has no subject for implementation unit {unit}",
        )
    subject = matching[0]
    if subject["stageManifestId"] != manifest["manifestId"]:
        fail(
            "classification",
            "classification stage artifact identity is stale or mismatched",
        )
    if subject["artifactIdentity"] != evidence["artifactIdentity"]:
        fail(
            "classification",
            "classification checkpoint artifact identity is stale or mismatched",
        )
    if subject["sourceIdentity"] != evidence["sourceIdentity"]:
        fail("classification", "classification source identity is stale or mismatched")

    exception = subject["timingExceptionReport"]
    require_exact_keys(
        exception,
        ("reportSha256", "classification", "rationale"),
        "classification",
        "timing-exception classification",
    )
    if exception["reportSha256"] != evidence["timingExceptionSet"]["reportSha256"]:
        fail(
            "classification",
            "timing-exception classification report hash is mismatched",
        )
    if exception["classification"] != "explicit-exact-report":
        fail(
            "classification",
            "timing exceptions require explicit-exact-report classification",
        )
    if (
        not isinstance(exception["rationale"], str)
        or not exception["rationale"].strip()
    ):
        fail("classification", "timing-exception classification requires a rationale")

    classified_endpoints = subject["unconstrainedEndpoints"]
    if not isinstance(classified_endpoints, list):
        fail(
            "classification", "unconstrained endpoint classifications must be an array"
        )
    observed_by_id = {
        entry["id"]: entry for entry in evidence["unconstrainedEndpoints"]
    }
    for observed in observed_by_id.values():
        if (
            observed["category"] != "unconstrained_internal_endpoints"
            or observed["reason"] != "constant-clock"
        ):
            fail(
                "classification",
                "strict signoff permits only constant-clock unconstrained internal endpoints",
            )
        if not any(
            clock_pin["constantValue"] in ("0", "1")
            for clock_pin in observed["clockPins"]
        ):
            fail(
                "classification",
                f"constant-clock endpoint lacks exact constant clock-pin evidence: {observed['endpoint']}",
            )

    classified_by_id = {}
    for entry in classified_endpoints:
        require_exact_keys(
            entry,
            (
                "id",
                "category",
                "endpoint",
                "reason",
                "clockPins",
                "classification",
                "rationale",
            ),
            "classification",
            "unconstrained endpoint classification",
        )
        identifier = entry["id"]
        if (
            not isinstance(identifier, str)
            or re.fullmatch(r"[0-9a-f]{64}", identifier) is None
        ):
            fail("classification", "endpoint classification ID must be a SHA-256 value")
        if identifier in classified_by_id:
            fail("classification", "duplicate unconstrained endpoint classification")
        if (
            not isinstance(entry["endpoint"], str)
            or "*" in entry["endpoint"]
            or "?" in entry["endpoint"]
        ):
            fail(
                "classification",
                "endpoint classifications must use exact names without wildcards",
            )
        if entry["classification"] != "intentional-constant-clock":
            fail(
                "classification",
                "constant-clock endpoints require intentional-constant-clock classification",
            )
        if not isinstance(entry["rationale"], str) or not entry["rationale"].strip():
            fail("classification", "endpoint classification requires a rationale")
        classified_by_id[identifier] = entry
    if set(classified_by_id) != set(observed_by_id):
        missing = sorted(set(observed_by_id) - set(classified_by_id))
        extra = sorted(set(classified_by_id) - set(observed_by_id))
        fail(
            "classification",
            f"unconstrained endpoint classification is not exact (missing={len(missing)}, extra={len(extra)})",
        )
    for identifier, observed in observed_by_id.items():
        classified = classified_by_id[identifier]
        for key in ("category", "endpoint", "reason", "clockPins"):
            if classified[key] != observed[key]:
                fail(
                    "classification",
                    f"classified endpoint {identifier} has mismatched {key}",
                )
    return sha256_file(path)


def verify_core(args):
    stage = args.stage.resolve(strict=True)
    manifest = load_json(stage / "metadata" / "stage.json", "stage")
    validate_manifest_identity(stage, manifest)
    if manifest.get("phase") != "validate":
        fail("stage", "strict signoff requires a validate-stage manifest")
    context = manifest.get("context")
    if not isinstance(context, dict) or context.get("id") != args.context:
        fail("stage", "strict-signoff stage context is mismatched")
    unit = manifest.get("unit")
    if not isinstance(unit, str) or not unit:
        fail("stage", "strict-signoff stage unit is missing")
    if manifest.get("outcome") != "accepted":
        fail("validation", "implementation validation outcome is not accepted")
    artifacts = manifest_artifacts(stage, manifest)

    missing_roles = [
        role for role in REQUIRED_VALIDATE_ROLES.values() if role not in artifacts
    ]
    for role in (
        "physical-observations",
        "validation-result",
        "validate-strict-signoff-evidence",
    ):
        if role not in artifacts:
            missing_roles.append(role)
    if missing_roles:
        fail(
            "reports",
            f"validate stage is missing required signoff roles: {', '.join(sorted(missing_roles))}",
        )

    report_paths = {
        kind: artifacts[role][1] for kind, role in REQUIRED_VALIDATE_ROLES.items()
    }
    evidence = build_evidence(
        stage,
        "validate",
        unit,
        context,
        artifacts["validated-checkpoint"][1],
        report_paths,
    )
    published_evidence = load_json(
        artifacts["validate-strict-signoff-evidence"][1], "reports"
    )
    if published_evidence != evidence:
        fail("reports", "published strict-signoff evidence is stale or mismatched")

    validation = load_json(artifacts["validation-result"][1], "validation")
    if validation.get("outcome") != "accepted":
        fail("validation", "validation report outcome is not accepted")
    physical = load_json(artifacts["physical-observations"][1], "timing")
    validate_physical(physical, evidence)

    if args.classification is None:
        fail(
            "classification",
            "an explicit immutable strict-signoff classification is required",
        )
    classification_sha256 = validate_classification(
        args.classification.resolve(strict=True), manifest, evidence
    )
    return {
        "contextId": context["id"],
        "unit": unit,
        "stageManifestId": manifest["manifestId"],
        "evidenceId": evidence["evidenceId"],
        "artifactIdentity": evidence["artifactIdentity"],
        "sourceIdentity": evidence["sourceIdentity"],
        "classificationSha256": classification_sha256,
    }


def verify(args):
    subject = {
        "contextId": args.context,
        "unit": None,
        "stageManifestId": None,
        "evidenceId": None,
        "artifactIdentity": None,
        "sourceIdentity": None,
        "classificationSha256": None,
    }
    try:
        subject.update(verify_core(args))
        outcome = "accepted"
        failed_checks = []
        reasons = []
        status = 0
    except (ContractError, OSError) as error:
        outcome = "rejected"
        failed_checks = [
            error.category if isinstance(error, ContractError) else "stage"
        ]
        reasons = [str(error)]
        status = 1
    result = {
        "schemaVersion": 1,
        "api": RESULT_API,
        "outcome": outcome,
        **subject,
        "failedChecks": failed_checks,
        "reasons": reasons,
    }
    atomic_write(args.output, canonical(result))
    return status


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    collect_parser = commands.add_parser("collect")
    collect_parser.add_argument("--root", type=Path, required=True)
    collect_parser.add_argument("--phase", choices=PHASES, required=True)
    collect_parser.add_argument("--unit", required=True)
    collect_parser.add_argument("--context", type=Path, required=True)
    collect_parser.add_argument("--checkpoint", type=Path, required=True)
    collect_parser.add_argument("--report-directory", required=True)
    collect_parser.add_argument("--report-prefix", required=True)
    collect_parser.add_argument("--report-suffix", default="")
    collect_parser.add_argument("--output", type=Path, required=True)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--stage", type=Path, required=True)
    verify_parser.add_argument("--context", required=True)
    verify_parser.add_argument("--classification", type=Path)
    verify_parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "collect":
            collect(args)
            return 0
        return verify(args)
    except (ContractError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
