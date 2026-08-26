#!/usr/bin/env python3
"""Write, validate, and import immutable Coyote implementation-stage artifacts."""

import argparse
from decimal import Decimal, InvalidOperation
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tempfile

STAGE_APIS = {
    1: "coyote-nix.implementation-stage/v1",
    2: "coyote-nix.implementation-stage/v2",
}
TELEMETRY_API = "coyote-nix.implementation-telemetry/v1"
PHASES = ("inputs", "link", "opt", "place", "route", "validate", "finalize", "image")
TRANSITIONS = {
    "inputs": {None},
    "link": {"inputs"},
    "opt": {"link"},
    "place": {"link", "opt"},
    "route": {"place"},
    "validate": {"route"},
    "finalize": {"validate"},
    "image": {"validate", "finalize"},
}


def fail(message: str) -> None:
    raise ValueError(message)


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_json_constant(value):
    raise ValueError(f"non-finite JSON value: {value}")


def load_json(path: Path):
    try:
        with path.open("r", encoding="utf-8") as stream:
            return json.load(
                stream,
                object_pairs_hook=strict_object,
                parse_constant=reject_json_constant,
            )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        fail(f"cannot read JSON {path}: {error}")


def canonical(value) -> bytes:
    return (json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False
    ) + "\n").encode()


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


def decimal_integer(value, scale: int, field: str) -> int:
    if not isinstance(value, (str, int, float)) or isinstance(value, bool):
        fail(f"{field} must be a decimal string or number")
    try:
        decimal = Decimal(str(value))
    except InvalidOperation:
        fail(f"{field} is not a decimal number")
    if not decimal.is_finite():
        fail(f"{field} must be finite")
    scaled = decimal * scale
    if scaled != scaled.to_integral_value():
        fail(f"{field} loses precision in the canonical unit")
    return int(scaled)


def nonnegative_decimal_integer(value, scale: int, field: str) -> int:
    result = decimal_integer(value, scale, field)
    if result < 0:
        fail(f"{field} must not be negative")
    return result


def metric_available(value: int, unit: str, role: str):
    return {
        "state": "available",
        "value": value,
        "unit": unit,
        "sources": [{"kind": "artifact", "role": role}],
    }


def metric_unavailable(unit: str, reason: str):
    return {"state": "unavailable", "unit": unit, "reason": reason, "sources": []}


def optional_decimal_metric(document, key: str, scale: int, unit: str, role: str, applicable: bool):
    value = document.get(key)
    if value is None:
        return metric_unavailable(unit, "not-published" if applicable else "not-applicable")
    if not applicable:
        fail(f"{key} is not applicable to this phase")
    return metric_available(decimal_integer(value, scale, key), unit, role)


def optional_integer_metric(document, key: str, unit: str, role: str, applicable: bool):
    value = document.get(key)
    if value is None:
        return metric_unavailable(unit, "not-published" if applicable else "not-applicable")
    if not applicable:
        fail(f"{key} is not applicable to this phase")
    if not isinstance(value, int) or isinstance(value, bool):
        fail(f"{key} must be an integer or null")
    if value < 0:
        fail(f"{key} must not be negative")
    if key == "rqaScore" and not 1 <= value <= 5:
        fail("rqaScore must be between 1 and 5")
    if key == "hasRoutingErrors" and value not in (0, 1):
        fail("hasRoutingErrors must be zero or one")
    return metric_available(value, unit, role)


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
        if key in resources:
            continue
        used = cells[header["used"]].replace(",", "")
        available = cells[header["available"]].replace(",", "")
        if used in ("", "-", "N/A") or available in ("", "-", "N/A"):
            continue
        resources[key] = {
            "used": decimal_integer(used, scale, f"utilization {label} used"),
            "available": decimal_integer(available, scale, f"utilization {label} available"),
            "unit": unit,
        }
    required = {"lut", "register", "bramTiles", "dsp"}
    if not required.issubset(resources):
        missing = ", ".join(sorted(required - set(resources)))
        fail(f"utilization report is incomplete ({missing}): {path}")
    return resources


def recipe_identity(phase, unit, context, predecessor, strategy, resources):
    recipe = {
        "executorApi": "coyote-nix.implementation-executor/v1",
        "phase": phase,
        "unit": unit,
        "contextId": context["id"],
        "predecessorRecipeId": None if predecessor is None else predecessor.get("recipeId", predecessor["manifestId"]),
        "strategy": strategy,
        "resources": resources,
    }
    return hashlib.sha256(canonical(recipe)).hexdigest()


def write_telemetry(
    telemetry_spec, artifact_root: Path, output_path: Path, phase, unit, context,
    predecessor, strategy, resources, outcome, declarations
):
    if not isinstance(telemetry_spec, dict) or set(telemetry_spec) != {
        "path", "executionPath", "physicalPath"
    }:
        fail("telemetry specification requires exactly path, executionPath, and physicalPath")
    relative_output = safe_relative(telemetry_spec["path"])
    if output_path != artifact_root.joinpath(*relative_output.parts):
        fail("telemetry output path is inconsistent")
    declared_by_role = {}
    for declaration in declarations:
        role = declaration.get("role")
        if role in declared_by_role:
            fail(f"duplicate artifact declaration role: {role}")
        declared_by_role[role] = declaration.get("path")
    execution_relative = safe_relative(telemetry_spec["executionPath"])
    if declared_by_role.get("execution-evidence") != str(execution_relative):
        fail("execution evidence role/path does not match telemetry source")
    if declared_by_role.get("normalized-telemetry") != str(relative_output):
        fail("normalized telemetry role/path does not match telemetry output")
    if declared_by_role.get("raw-resource-measurement") != "metadata/gnu-time.txt":
        fail("telemetry requires canonical raw resource measurement evidence")
    execution = load_json(resolve_contained(artifact_root, execution_relative))
    raw_measurement_path = resolve_contained(
        artifact_root, safe_relative(declared_by_role["raw-resource-measurement"])
    )
    try:
        raw_measurement = {}
        for line in raw_measurement_path.read_text(encoding="utf-8").splitlines():
            if not line:
                continue
            key, value = line.split("=", 1)
            if key in raw_measurement:
                fail(f"duplicate raw resource measurement: {key}")
            raw_measurement[key] = value
    except (OSError, ValueError) as error:
        fail(f"cannot parse raw resource measurement: {error}")
    required_measurements = {
        "wallSeconds", "userCpuSeconds", "systemCpuSeconds", "maxRssKiB", "exitCode"
    }
    if set(raw_measurement) != required_measurements:
        fail("raw resource measurement has unexpected fields")
    if any(str(execution.get(key)) != raw_measurement[key] for key in (
        "wallSeconds", "userCpuSeconds", "systemCpuSeconds", "maxRssKiB", "exitCode"
    )):
        fail("execution evidence does not match raw resource measurement")
    if execution.get("schemaVersion") != 1 or execution.get("kind") != "coyote-stage-execution":
        fail("unsupported execution evidence")
    if execution.get("status") != "completed" or execution.get("exitCode") != 0:
        fail("published implementation stage requires completed execution evidence")
    if execution.get("measurementScope") != "build-commands":
        fail("unsupported execution measurement scope")
    requested_cores = execution.get("requestedCores")
    if not isinstance(requested_cores, int) or isinstance(requested_cores, bool) or requested_cores <= 0:
        fail("execution requestedCores must be positive")
    expected_cores = resources.get("cores")
    if expected_cores is not None and requested_cores != expected_cores:
        fail("execution requested cores do not match stage resources")
    for key in ("maxRssKiB", "scratchBytesAfterCommand"):
        if not isinstance(execution.get(key), int) or isinstance(execution[key], bool) or execution[key] < 0:
            fail(f"execution {key} must be a non-negative integer")
    primary_tool = execution.get("primaryTool")
    if "primary-tool-invocation" in declared_by_role and primary_tool is None:
        fail("declared primary tool invocation is missing from execution evidence")
    if primary_tool is not None:
        if declared_by_role.get("primary-tool-invocation") != "metadata/primary-tool.json":
            fail("primary tool evidence is not declared at its canonical path")
        primary_document = load_json(resolve_contained(
            artifact_root, safe_relative(declared_by_role["primary-tool-invocation"])
        ))
        if primary_document != primary_tool:
            fail("execution primary tool evidence does not match declared artifact")
        if not isinstance(primary_tool, dict) or primary_tool.get("schemaVersion") != 1 or primary_tool.get("kind") != "coyote-primary-tool-invocation":
            fail("unsupported primary tool invocation evidence")
        primary_exit = primary_tool.get("exitCode")
        if not isinstance(primary_exit, int) or isinstance(primary_exit, bool) or primary_exit < 0:
            fail("primary tool exitCode must be non-negative")
        marker = primary_tool.get("completionMarkerObserved")
        if not isinstance(marker, bool):
            fail("primary tool completionMarkerObserved must be Boolean")
        if not marker:
            fail("published primary tool invocation requires its completion marker")
        expected_anomaly = "post-completion-nonzero-exit" if primary_exit != 0 and marker else None
        if primary_tool.get("anomaly") != expected_anomaly:
            fail("primary tool anomaly is inconsistent")

    physical = None
    utilization_resources = None
    utilization_role = None
    physical_relative = telemetry_spec["physicalPath"]
    if physical_relative is None and "physical-observations" in declared_by_role:
        fail("physical observation artifact requires a telemetry physicalPath")
    if physical_relative is not None:
        physical_relative = safe_relative(physical_relative)
        if declared_by_role.get("physical-observations") != str(physical_relative):
            fail("physical observation role/path does not match telemetry source")
        physical_path = resolve_contained(artifact_root, physical_relative)
        physical = load_json(physical_path)
        if physical.get("schemaVersion") != 1 or physical.get("kind") != "coyote-implementation-observations":
            fail("unsupported physical observation evidence")
        if physical.get("phase") != phase:
            fail("physical observation phase does not match stage")
        expected_analysis_kind = "routed" if phase in ("route", "validate") else "estimated"
        if physical.get("analysisKind") != expected_analysis_kind:
            fail(f"physical analysis kind must be {expected_analysis_kind} for {phase}")
        required_physical_keys = {
            "timing": {"setupWnsNs", "setupTnsNs", "holdWnsNs", "holdTnsNs"},
            "qor": {"rqaScore"},
            "routing": {"unroutedNets", "partiallyRoutedNets", "conflictedNets", "hasRoutingErrors"},
            "drc": {"errors", "criticalWarnings", "warnings"},
            "reports": {"utilization", "timingSummary", "qorAssessment", "routeStatus"},
        }
        for section, required_keys in required_physical_keys.items():
            section_value = physical.get(section)
            if not isinstance(section_value, dict) or set(section_value) != required_keys:
                fail(f"physical observations require exact {section} fields")
        utilization_name = physical["reports"].get("utilization")
        utilization_relative_name = safe_relative(utilization_name)
        if len(utilization_relative_name.parts) != 1:
            fail("physical utilization report must be adjacent to observation evidence")
        utilization_relative = physical_relative.parent / utilization_relative_name
        for declaration in declarations:
            if declaration.get("path") == str(utilization_relative):
                utilization_role = declaration.get("role")
                break
        if not isinstance(utilization_role, str) or not utilization_role:
            fail("physical utilization report is not declared as stage evidence")
        utilization_resources = parse_utilization_report(
            resolve_contained(artifact_root, utilization_relative)
        )
        report_requirements = {
            "timingSummary": True,
            "qorAssessment": phase in ("opt", "place"),
            "routeStatus": phase in ("route", "validate"),
        }
        for report_key, required in report_requirements.items():
            report_name = physical["reports"].get(report_key)
            if not required:
                if report_name != "":
                    fail(f"{report_key} is not applicable to {phase}")
                continue
            report_relative_name = safe_relative(report_name)
            if len(report_relative_name.parts) != 1:
                fail(f"physical {report_key} report must be adjacent to observation evidence")
            report_relative = physical_relative.parent / report_relative_name
            if not any(declaration.get("path") == str(report_relative) for declaration in declarations):
                fail(f"physical {report_key} report is not declared as stage evidence")
            resolve_contained(artifact_root, report_relative)

    declared_payload_bytes = 0
    for declaration in declarations:
        relative = safe_relative(declaration["path"])
        if relative == relative_output:
            continue
        declared_payload_bytes += resolve_contained(artifact_root, relative).stat().st_size

    recipe_id = recipe_identity(phase, unit, context, predecessor, strategy, resources)
    execution_role = "execution-evidence"
    physical_role = "physical-observations"
    runtime = {
        "wallNs": metric_available(nonnegative_decimal_integer(execution["wallSeconds"], 1_000_000_000, "wallSeconds"), "ns", execution_role),
        "userCpuNs": metric_available(nonnegative_decimal_integer(execution["userCpuSeconds"], 1_000_000_000, "userCpuSeconds"), "ns", execution_role),
        "systemCpuNs": metric_available(nonnegative_decimal_integer(execution["systemCpuSeconds"], 1_000_000_000, "systemCpuSeconds"), "ns", execution_role),
        "peakRssBytes": metric_available(execution["maxRssKiB"] * 1024, "byte", execution_role),
        "scratchBytesAfterCommand": metric_available(execution["scratchBytesAfterCommand"], "byte", execution_role),
        "retainedDeclaredPayloadBytes": {
            "state": "available",
            "value": declared_payload_bytes,
            "unit": "byte",
            "sources": [{"kind": "manifest", "locator": "artifacts[].size"}],
        },
    }
    unavailable_timing = {
        key: metric_unavailable("fs", "not-applicable")
        for key in ("setupWnsFs", "setupTnsFs", "holdWnsFs", "holdTnsFs")
    }
    unavailable_routing = {
        key: metric_unavailable("count", "not-applicable")
        for key in ("unroutedNets", "partiallyRoutedNets", "conflictedNets", "hasRoutingErrors")
    }
    unavailable_drc = {
        key: metric_unavailable("count", "not-applicable")
        for key in ("errors", "criticalWarnings", "warnings")
    }
    if physical is None:
        tool = {
            "requestedId": context["toolId"],
            "observedVersion": None,
            "observedFullVersion": None,
        }
        analysis_kind = "none"
        timing = unavailable_timing
        qor = {"rqaScore": metric_unavailable("score", "not-applicable")}
        routing = unavailable_routing
        drc = unavailable_drc
        utilization = {
            key: {
                "used": metric_unavailable(resource_unit, "not-applicable"),
                "available": metric_unavailable(resource_unit, "not-applicable"),
            }
            for key, resource_unit in {
                "lut": "count", "register": "count", "bramTiles": "milli-tile",
                "uram": "count", "dsp": "count"
            }.items()
        }
    else:
        tool = {
            "requestedId": context["toolId"],
            "observedVersion": physical.get("vivadoVersion"),
            "observedFullVersion": physical.get("vivadoFullVersion"),
        }
        if not all(isinstance(tool[key], str) and tool[key] for key in ("observedVersion", "observedFullVersion")):
            fail("physical observations require Vivado version identity")
        expected_tool_version = context.get("toolVersion")
        if expected_tool_version is not None:
            if not isinstance(expected_tool_version, str) or not expected_tool_version:
                fail("context toolVersion must be a non-empty string")
            if tool["observedVersion"] != expected_tool_version:
                fail("observed Vivado version does not match requested tool version")
        analysis_kind = physical["analysisKind"]
        timing_values = physical["timing"]
        timing = {
            "setupWnsFs": optional_decimal_metric(timing_values, "setupWnsNs", 1_000_000, "fs", physical_role, analysis_kind != "none"),
            "setupTnsFs": optional_decimal_metric(timing_values, "setupTnsNs", 1_000_000, "fs", physical_role, analysis_kind != "none"),
            "holdWnsFs": optional_decimal_metric(timing_values, "holdWnsNs", 1_000_000, "fs", physical_role, analysis_kind != "none"),
            "holdTnsFs": optional_decimal_metric(timing_values, "holdTnsNs", 1_000_000, "fs", physical_role, analysis_kind != "none"),
        }
        qor = {
            "rqaScore": optional_integer_metric(physical["qor"], "rqaScore", "score", physical_role, phase in ("opt", "place"))
        }
        routing = {
            key: optional_integer_metric(physical["routing"], key, "count", physical_role, phase in ("route", "validate"))
            for key in unavailable_routing
        }
        drc = {
            key: optional_integer_metric(physical["drc"], key, "count", physical_role, phase == "validate")
            for key in unavailable_drc
        }
        utilization = {}
        for key, resource_unit in {
            "lut": "count", "register": "count", "bramTiles": "milli-tile",
            "uram": "count", "dsp": "count"
        }.items():
            observation = utilization_resources.get(key)
            if observation is None:
                utilization[key] = {
                    "used": metric_unavailable(resource_unit, "not-published"),
                    "available": metric_unavailable(resource_unit, "not-published"),
                }
            else:
                if observation["unit"] != resource_unit:
                    fail(f"unexpected utilization unit for {key}")
                utilization[key] = {
                    "used": metric_available(observation["used"], resource_unit, utilization_role),
                    "available": metric_available(observation["available"], resource_unit, utilization_role),
                }

    telemetry = {
        "schemaVersion": 1,
        "api": TELEMETRY_API,
        "subject": {
            "recipeId": recipe_id,
            "contextId": context["id"],
            "phase": phase,
            "unit": unit,
            "predecessorManifestId": None if predecessor is None else predecessor["manifestId"],
        },
        "tool": tool,
        "execution": {
            "status": execution["status"],
            "exitCode": execution["exitCode"],
            "measurementScope": execution["measurementScope"],
            "requestedCores": requested_cores,
            "primaryTool": primary_tool,
        },
        "metrics": {
            "runtime": runtime,
            "physical": {
                "analysisKind": analysis_kind,
                "timing": timing,
                "qor": qor,
                "utilization": utilization,
                "routing": routing,
                "drc": drc,
            },
        },
        "outcome": outcome,
    }
    telemetry_id = hashlib.sha256(canonical(telemetry)).hexdigest()
    telemetry["telemetryId"] = telemetry_id
    atomic_write(output_path, canonical(telemetry))
    return recipe_id, telemetry_id, str(relative_output)


def validate_telemetry(stage_dir: Path, manifest, artifact):
    relative = safe_relative(artifact["path"])
    telemetry = load_json(resolve_contained(stage_dir, relative))
    if telemetry.get("schemaVersion") != 1 or telemetry.get("api") != TELEMETRY_API:
        fail("unsupported implementation telemetry API")
    telemetry_without_id = dict(telemetry)
    telemetry_id = telemetry_without_id.pop("telemetryId", None)
    if telemetry_id != hashlib.sha256(canonical(telemetry_without_id)).hexdigest():
        fail("telemetry ID mismatch")
    subject = telemetry.get("subject")
    expected_recipe = recipe_identity(
        manifest["phase"], manifest["unit"], manifest["context"], manifest["predecessor"],
        manifest.get("strategy", {}), manifest.get("resources", {})
    )
    if not isinstance(subject, dict) or subject.get("recipeId") != expected_recipe:
        fail("telemetry recipe identity mismatch")
    if subject.get("contextId") != manifest["context"]["id"] or subject.get("phase") != manifest["phase"] or subject.get("unit") != manifest["unit"]:
        fail("telemetry subject does not match stage manifest")
    expected_predecessor = None if manifest["predecessor"] is None else manifest["predecessor"]["manifestId"]
    if subject.get("predecessorManifestId") != expected_predecessor:
        fail("telemetry predecessor does not match stage manifest")
    if telemetry.get("outcome") != manifest["outcome"]:
        fail("telemetry outcome does not match stage manifest")
    if manifest.get("recipeId") != expected_recipe:
        fail("stage recipe identity mismatch")
    reference = manifest.get("telemetry")
    if reference != {"api": TELEMETRY_API, "path": str(relative), "telemetryId": telemetry_id}:
        fail("stage telemetry reference mismatch")


def validate_manifest(stage_dir: Path, expected_phase=None, expected_context=None):
    manifest_path = stage_dir / "metadata" / "stage.json"
    complete_path = stage_dir / "metadata" / "complete"
    manifest = load_json(manifest_path)
    schema_version = manifest.get("schemaVersion")
    if schema_version not in STAGE_APIS or manifest.get("api") != STAGE_APIS[schema_version]:
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
    telemetry_artifact = artifacts_by_role.get("normalized-telemetry")
    expected_recipe = recipe_identity(
        phase, unit, context, predecessor, manifest.get("strategy", {}), manifest.get("resources", {})
    )
    if schema_version == 2 and manifest.get("recipeId") != expected_recipe:
        fail("version-2 stage recipe identity mismatch")
    if telemetry_artifact is None:
        if "telemetry" in manifest:
            fail("stage telemetry reference requires normalized-telemetry artifact")
        if schema_version == 2 and phase != "inputs":
            fail("version-2 non-input stage requires normalized telemetry")
    else:
        for required_role in ("execution-evidence", "raw-resource-measurement", "command-stdout", "command-stderr"):
            if required_role not in artifacts_by_role:
                fail(f"telemetry stage requires {required_role}")
        validate_telemetry(stage_dir, manifest, telemetry_artifact)
    if schema_version == 1 and "recipeId" in manifest and manifest["recipeId"] != expected_recipe:
        fail("stage recipe identity mismatch")
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
    schema_version = spec.get("schemaVersion", 1)
    if not isinstance(schema_version, int) or isinstance(schema_version, bool) or schema_version not in STAGE_APIS:
        fail("unsupported stage specification schemaVersion")
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
            "recipeId": previous.get("recipeId", previous["manifestId"]),
        }
    elif predecessor_path is not None:
        fail("inputs stage must not have a predecessor")
    declarations = spec.get("artifacts")
    if not isinstance(declarations, list) or not declarations:
        fail("stage specification must declare artifacts")
    for declaration in declarations:
        if not isinstance(declaration, dict) or set(declaration) != {"role", "path"}:
            fail("artifact declaration must contain exactly role and path")
        if not isinstance(declaration["role"], str) or not declaration["role"]:
            fail("artifact declaration role must be non-empty")
        safe_relative(declaration["path"])
    unit = spec.get("unit")
    if not isinstance(unit, str) or not unit:
        fail("stage specification requires unit")
    strategy = spec.get("strategy", {})
    resources = spec.get("resources", {})
    if not isinstance(strategy, dict) or not isinstance(resources, dict):
        fail("stage strategy and resources must be objects")
    outcome = spec.get("outcome", "complete")
    if outcome_path is not None:
        relative_outcome = safe_relative(outcome_path)
        outcome_document = load_json(resolve_contained(artifact_root, relative_outcome))
        outcome = outcome_document.get("outcome")
    if outcome not in ("complete", "accepted", "rejected", "tool-failure"):
        fail("invalid stage outcome")

    telemetry_spec = spec.get("telemetry")
    if schema_version == 2 and phase != "inputs" and telemetry_spec is None:
        fail("version-2 non-input stage requires telemetry specification")
    recipe_id = recipe_identity(phase, unit, context, predecessor, strategy, resources)
    telemetry_reference = None
    if telemetry_spec is not None:
        if not isinstance(telemetry_spec, dict):
            fail("telemetry specification must be an object")
        telemetry_relative = safe_relative(telemetry_spec.get("path"))
        telemetry_recipe_id, telemetry_id, telemetry_path = write_telemetry(
            telemetry_spec,
            artifact_root,
            artifact_root.joinpath(*telemetry_relative.parts),
            phase,
            unit,
            context,
            predecessor,
            strategy,
            resources,
            outcome,
            declarations,
        )
        if telemetry_recipe_id != recipe_id:
            fail("telemetry recipe identity is inconsistent")
        telemetry_reference = {
            "api": TELEMETRY_API,
            "path": telemetry_path,
            "telemetryId": telemetry_id,
        }

    artifacts = []
    for declaration in declarations:
        relative = safe_relative(declaration["path"])
        source = resolve_contained(artifact_root, relative)
        artifacts.append({
            "role": declaration["role"],
            "path": str(relative),
            "sha256": sha256_file(source),
            "size": source.stat().st_size,
        })
    manifest = {
        "schemaVersion": schema_version,
        "api": STAGE_APIS[schema_version],
        "phase": phase,
        "unit": unit,
        "context": context,
        "predecessor": predecessor,
        "strategy": strategy,
        "resources": resources,
        "outcome": outcome,
        "artifacts": artifacts,
    }
    if schema_version == 2 or telemetry_reference is not None:
        manifest["recipeId"] = recipe_id
    if telemetry_reference is not None:
        manifest["telemetry"] = telemetry_reference
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
    utilization = subparsers.add_parser("parse-utilization")
    utilization.add_argument("report", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "write":
            write_manifest(args.spec, args.artifact_root, args.output_dir)
        elif args.command == "validate":
            validate_manifest(args.stage_dir, args.phase, args.context)
        elif args.command == "import":
            import_artifacts(args.stage_dir, args.destination, args.roles)
        else:
            sys.stdout.buffer.write(canonical(parse_utilization_report(args.report)))
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
