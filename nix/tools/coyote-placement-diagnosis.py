#!/usr/bin/env python3
"""Normalize immutable V80 placement evidence and produce advisory recommendations."""

import argparse
from decimal import Decimal, InvalidOperation
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys

DIAGNOSIS_API = "coyote-nix.placement-diagnosis/v1"
RECOMMENDATION_API = "coyote-nix.placement-recommendation/v1"


def fail(message):
    raise ValueError(message)


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load(path):
    try:
        with path.open("r", encoding="utf-8") as stream:
            return json.load(
                stream,
                object_pairs_hook=strict_object,
                parse_constant=lambda value: fail(f"non-finite JSON value: {value}"),
            )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        fail(f"cannot read JSON {path}: {error}")


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()


def atomic_write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(canonical(value))
    temporary.replace(path)


def safe_relative(raw):
    if not isinstance(raw, str) or not raw:
        fail("artifact path must be a non-empty string")
    path = PurePosixPath(raw)
    if path.is_absolute() or ".." in path.parts or "." in path.parts or str(path) != raw:
        fail(f"unsafe artifact path: {raw}")
    return path


def artifact_path(stage, manifest, role):
    matches = [entry for entry in manifest["artifacts"] if entry.get("role") == role]
    if len(matches) != 1:
        fail(f"stage requires exactly one {role} artifact")
    relative = safe_relative(matches[0].get("path"))
    path = stage.joinpath(*relative.parts)
    if not path.is_file():
        fail(f"missing {role} artifact: {relative}")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != matches[0].get("sha256"):
        fail(f"tampered {role} artifact: {relative}")
    return path, str(relative)


def decimal_scaled(value, scale, field):
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        fail(f"{field} must be numeric or null")
    try:
        number = Decimal(str(value))
    except InvalidOperation:
        fail(f"{field} is malformed")
    if not number.is_finite():
        fail(f"{field} must be finite")
    scaled = number * scale
    if scaled != scaled.to_integral_value():
        fail(f"{field} loses precision")
    return int(scaled)


def metric(value, unit, source, reason="not-published"):
    if value is None:
        return {"state": "unavailable", "unit": unit, "reason": reason, "sources": []}
    return {
        "state": "available",
        "value": value,
        "unit": unit,
        "sources": [{"kind": "artifact", "role": source}],
    }


def parse_congestion_level(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    matches = re.findall(r"(?im)^\s*(?:overall\s+)?congestion\s+level\s*[:|]\s*([0-9]+)\s*(?:\||$)", text)
    if not matches:
        return None
    values = {int(value) for value in matches}
    if len(values) != 1:
        fail("congestion report contains conflicting overall levels")
    value = values.pop()
    if value < 0 or value > 8:
        fail("congestion level is outside the supported range")
    return value


def normalize(stage, output, candidate_id):
    manifest = load(stage / "metadata/stage.json")
    if manifest.get("api") != "coyote-nix.implementation-stage/v2" or manifest.get("phase") != "place":
        fail("placement diagnosis requires a strict place-stage v2 manifest")
    context = manifest.get("context")
    if not isinstance(context, dict) or context.get("architecture") != "versal" or context.get("board") != "v80":
        fail("placement diagnosis currently supports only V80 Versal stages")
    strategy = manifest.get("strategy")
    if not isinstance(strategy, dict):
        fail("place-stage strategy must be an object")
    declared_candidate = strategy.get("candidateId")
    if candidate_id is None:
        candidate_id = declared_candidate or "canonical"
    if declared_candidate is not None and declared_candidate != candidate_id:
        fail("candidate identifier does not match the place-stage strategy")
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", candidate_id):
        fail("candidate identifier is not canonical")

    evidence_path, evidence_relative = artifact_path(stage, manifest, "place-diagnosis-observations")
    congestion_path, congestion_relative = artifact_path(stage, manifest, "place-congestion-report")
    _, complexity_relative = artifact_path(stage, manifest, "place-complexity-report")
    _, logic_levels_relative = artifact_path(stage, manifest, "place-logic-level-report")
    _, high_fanout_relative = artifact_path(stage, manifest, "place-high-fanout-report")
    telemetry_path, telemetry_relative = artifact_path(stage, manifest, "normalized-telemetry")
    evidence = load(evidence_path)
    telemetry = load(telemetry_path)

    required_evidence = {
        "schemaVersion", "kind", "phase", "vivadoVersion", "vivadoFullVersion",
        "setupPathCount", "worstSetupPath", "reports",
    }
    if set(evidence) != required_evidence or evidence.get("schemaVersion") != 1 or evidence.get("kind") != "coyote-placement-diagnosis-evidence" or evidence.get("phase") != "place":
        fail("unsupported placement diagnosis evidence")
    path = evidence.get("worstSetupPath")
    required_path = {
        "source", "destination", "pathGroup", "slackNs", "requirementNs",
        "dataPathDelayNs", "logicDelayNs", "netDelayNs", "logicLevels", "skewNs",
    }
    if not isinstance(path, dict) or set(path) != required_path:
        fail("placement evidence has malformed worstSetupPath")
    if not isinstance(evidence.get("setupPathCount"), int) or evidence["setupPathCount"] < 0:
        fail("setupPathCount must be non-negative")
    reports = evidence.get("reports")
    expected_reports = {
        "congestion": PurePosixPath(congestion_relative).name,
        "complexity": PurePosixPath(complexity_relative).name,
        "logicLevels": PurePosixPath(logic_levels_relative).name,
        "highFanout": PurePosixPath(high_fanout_relative).name,
    }
    if reports != expected_reports:
        fail("placement evidence report references do not match declared artifacts")
    for field in ("source", "destination", "pathGroup"):
        if not isinstance(path[field], str):
            fail(f"worstSetupPath.{field} must be a string")

    values = {
        "slackFs": decimal_scaled(path["slackNs"], 1_000_000, "slackNs"),
        "requirementFs": decimal_scaled(path["requirementNs"], 1_000_000, "requirementNs"),
        "dataPathDelayFs": decimal_scaled(path["dataPathDelayNs"], 1_000_000, "dataPathDelayNs"),
        "logicDelayFs": decimal_scaled(path["logicDelayNs"], 1_000_000, "logicDelayNs"),
        "netDelayFs": decimal_scaled(path["netDelayNs"], 1_000_000, "netDelayNs"),
        "skewFs": decimal_scaled(path["skewNs"], 1_000_000, "skewNs"),
    }
    logic_levels = path["logicLevels"]
    if logic_levels is not None and (not isinstance(logic_levels, int) or isinstance(logic_levels, bool) or logic_levels < 0):
        fail("logicLevels must be a non-negative integer or null")
    data_delay = values["dataPathDelayFs"]
    logic_fraction = None
    net_fraction = None
    if data_delay is not None and data_delay > 0:
        if values["logicDelayFs"] is not None:
            logic_fraction = values["logicDelayFs"] * 1_000_000 // data_delay
        if values["netDelayFs"] is not None:
            net_fraction = values["netDelayFs"] * 1_000_000 // data_delay

    rqa_metric = telemetry.get("metrics", {}).get("physical", {}).get("qor", {}).get("rqaScore")
    if not isinstance(rqa_metric, dict) or rqa_metric.get("state") not in ("available", "unavailable"):
        fail("normalized telemetry lacks an explicit RQA metric state")
    diagnosis = {
        "schemaVersion": 1,
        "api": DIAGNOSIS_API,
        "subject": {
            "candidateId": candidate_id,
            "manifestId": manifest.get("manifestId"),
            "recipeId": manifest.get("recipeId"),
            "contextId": context.get("id"),
            "strategy": strategy,
        },
        "tool": {
            "observedVersion": evidence["vivadoVersion"],
            "observedFullVersion": evidence["vivadoFullVersion"],
        },
        "metrics": {
            "setupPathCount": metric(evidence["setupPathCount"], "count", "place-diagnosis-observations"),
            "rqaScore": rqa_metric,
            "congestionLevel": metric(parse_congestion_level(congestion_path), "level", "place-congestion-report", "unsupported-report-layout"),
            "worstSetupPath": {
                "source": path["source"],
                "destination": path["destination"],
                "pathGroup": path["pathGroup"],
                **{key: metric(value, "fs", "place-diagnosis-observations") for key, value in values.items()},
                "logicLevels": metric(logic_levels, "count", "place-diagnosis-observations"),
                "logicDelayFraction": metric(logic_fraction, "ppm", "place-diagnosis-observations"),
                "netDelayFraction": metric(net_fraction, "ppm", "place-diagnosis-observations"),
            },
        },
        "evidence": {
            "observations": evidence_relative,
            "telemetry": telemetry_relative,
            "congestionReport": congestion_relative,
            "complexityReport": complexity_relative,
            "logicLevelReport": logic_levels_relative,
            "highFanoutReport": high_fanout_relative,
        },
    }
    diagnosis["diagnosisId"] = hashlib.sha256(canonical(diagnosis)).hexdigest()
    atomic_write(output, diagnosis)


def available(metric_value, default):
    if isinstance(metric_value, dict) and metric_value.get("state") == "available":
        return metric_value.get("value")
    return default


def recommend(policy_path, output, diagnosis_paths):
    policy = load(policy_path)
    if set(policy) != {"schemaVersion", "api", "maxRouteCandidates", "weights"} or policy.get("schemaVersion") != 1 or policy.get("api") != "coyote-nix.placement-recommendation-policy/v1":
        fail("unsupported recommendation policy")
    maximum = policy["maxRouteCandidates"]
    if not isinstance(maximum, int) or isinstance(maximum, bool) or maximum < 1 or maximum > 2:
        fail("maxRouteCandidates must be one or two")
    weights = policy["weights"]
    required_weights = {"rqa", "setupSlackPerPs", "logicLevelPenalty", "congestionPenalty"}
    if not isinstance(weights, dict) or set(weights) != required_weights or any(not isinstance(value, int) or isinstance(value, bool) for value in weights.values()):
        fail("recommendation weights must be exact integer fields")
    diagnoses = [load(path) for path in diagnosis_paths]
    if len(diagnoses) < 2 or len(diagnoses) > 3:
        fail("recommendation requires two or three placement candidates")
    entries = []
    seen = set()
    contexts = set()
    for diagnosis in diagnoses:
        if diagnosis.get("api") != DIAGNOSIS_API:
            fail("recommendation input is not a placement diagnosis")
        subject = diagnosis.get("subject", {})
        candidate = subject.get("candidateId")
        if candidate in seen:
            fail(f"duplicate candidate identifier: {candidate}")
        seen.add(candidate)
        contexts.add(subject.get("contextId"))
        metrics = diagnosis.get("metrics", {})
        worst = metrics.get("worstSetupPath", {})
        rqa = available(metrics.get("rqaScore"), 0)
        slack_fs = available(worst.get("slackFs"), -10**15)
        levels = available(worst.get("logicLevels"), 10**6)
        congestion = available(metrics.get("congestionLevel"), 8)
        components = {
            "rqa": rqa * weights["rqa"],
            "setupSlack": (slack_fs // 1000) * weights["setupSlackPerPs"],
            "logicLevels": -levels * weights["logicLevelPenalty"],
            "congestion": -congestion * weights["congestionPenalty"],
        }
        entries.append({
            "candidateId": candidate,
            "diagnosisId": diagnosis.get("diagnosisId"),
            "score": sum(components.values()),
            "components": components,
        })
    if len(contexts) != 1 or None in contexts:
        fail("all recommendation candidates must share one context")
    entries.sort(key=lambda entry: (-entry["score"], entry["candidateId"]))
    recommendation = {
        "schemaVersion": 1,
        "api": RECOMMENDATION_API,
        "policy": policy,
        "contextId": next(iter(contexts)),
        "ranking": entries,
        "recommendedRouteCandidates": [entry["candidateId"] for entry in entries[:maximum]],
        "advisoryOnly": True,
    }
    recommendation["recommendationId"] = hashlib.sha256(canonical(recommendation)).hexdigest()
    atomic_write(output, recommendation)


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    normalize_parser = subparsers.add_parser("normalize")
    normalize_parser.add_argument("stage", type=Path)
    normalize_parser.add_argument("output", type=Path)
    normalize_parser.add_argument("--candidate-id")
    recommend_parser = subparsers.add_parser("recommend")
    recommend_parser.add_argument("policy", type=Path)
    recommend_parser.add_argument("output", type=Path)
    recommend_parser.add_argument("diagnoses", nargs="+", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "normalize":
            normalize(args.stage, args.output, args.candidate_id)
        else:
            recommend(args.policy, args.output, args.diagnoses)
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
