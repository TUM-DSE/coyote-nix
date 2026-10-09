#!/usr/bin/env python3
"""Compare hash-verified Coyote place/route stage directories without running implementation."""

import argparse
import importlib.util
import json
import re
import sys
from decimal import Decimal, InvalidOperation
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_sibling(filename, name):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load bundled parser {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


stage_api = load_sibling("coyote-implementation-stage.py", "stage_api")
signoff = load_sibling("coyote-strict-signoff.py", "signoff")


def fail(message):
    raise ValueError(message)


def artifact_by_role(root, manifest):
    return {
        item["role"]: root.joinpath(*stage_api.safe_relative(item["path"]).parts)
        for item in manifest["artifacts"]
    }


def finite_decimal(raw, field):
    try:
        value = Decimal(raw)
    except (InvalidOperation, TypeError):
        return None
    if not value.is_finite():
        return None
    return float(value)


def parse_clock_tables(text):
    clocks = {}
    lines = text.splitlines()
    # Vivado waveform is brace-delimited and therefore contains whitespace: do not split
    # the row into columns. Period is the numeric field immediately after the closing brace.
    in_clock_summary = False
    for index, line in enumerate(lines):
        if line.strip() == "| Clock Summary":
            in_clock_summary = True
            continue
        if in_clock_summary and line.strip().startswith("| Intra Clock Table"):
            break
        if not in_clock_summary or "Period(ns)" not in line:
            continue
        for row in lines[index + 2 :]:
            raw = row.strip()
            if raw.startswith("|") or raw.startswith("-") or not raw:
                if clocks:
                    break
                continue
            match = re.match(r"^(\S+)\s+\{[^}]*\}\s+(\S+)\s+(\S+)", raw)
            if match:
                period = finite_decimal(match.group(2), "clock period")
                clocks.setdefault(match.group(1), {})["periodNs"] = period

    in_intra = False
    for index, line in enumerate(lines):
        if line.strip() == "| Intra Clock Table":
            in_intra = True
            continue
        if not in_intra or "TNS Failing Endpoints" not in line:
            continue
        for row in lines[index + 2 :]:
            raw = row.strip()
            if not raw or raw.startswith("|") or raw.startswith("-"):
                if clocks and raw.startswith("|"):
                    break
                continue
            fields = raw.split()
            if len(fields) < 9:
                continue
            name = fields[0]
            try:
                numbers = [finite_decimal(fields[pos], "clock metric") for pos in (1, 2, 5, 6)]
                counts = [int(fields[pos].replace(",", "")) for pos in (3, 7)]
            except ValueError:
                break
            metrics = clocks.setdefault(name, {})
            keys = ("wnsNs", "tnsNs", "holdWnsNs", "holdTnsNs")
            metrics.update(dict(zip(keys, numbers)))
            metrics["failingEndpoints"], metrics["holdFailingEndpoints"] = counts
        break
    return clocks


def locate_role(roles, *needles):
    for role, path in roles.items():
        lowered = role.lower()
        if all(needle in lowered for needle in needles):
            return path
    return None


def parse_diagnostics(roles):
    route_path = locate_role(roles, "route-status")
    route = {"state": "unavailable", "reason": "report-not-declared", "metrics": None}
    if route_path is not None:
        route = {"state": "available", "evidence": str(route_path),
                 "metrics": signoff.parse_route_status(route_path.read_text(encoding="utf-8", errors="replace"))}
    drc_reports = {}
    for role, path in roles.items():
        if "drc" not in role.lower():
            continue
        kind = "bitstreamDrc" if "bitstream" in role.lower() else "drc"
        drc_reports[role] = {
            "evidence": str(path),
            "metrics": signoff.parse_drc(path.read_text(encoding="utf-8", errors="replace"), kind),
        }
    drc = {"state": "unavailable", "reason": "report-not-declared", "reports": {}}
    if drc_reports:
        drc = {"state": "available", "reports": drc_reports}
    return route, drc


def read_stage(directory):
    root = Path(directory)
    manifest = stage_api.validate_manifest(root)
    phase = manifest["phase"]
    if phase not in ("place", "route", "validate"):
        fail(f"{root}: stage {phase} is not placement/route evidence")
    # Rejected validation output is still valid diagnostic evidence, not acceptance.
    if manifest["outcome"] not in ("complete", "accepted", "rejected"):
        fail(f"{root}: stage outcome {manifest['outcome']} is not a completed physical receipt")
    context = manifest["context"]
    roles = artifact_by_role(root, manifest)
    timing = locate_role(roles, "timing-summary")
    if timing is None:
        fail(f"{root}: no declared timing summary report")
    text = timing.read_text(encoding="utf-8", errors="replace")
    # Existing signoff parser validates the supported overall Vivado summary format.
    overall = signoff.parse_timing_summary(text)
    clocks = parse_clock_tables(text)
    route, drc = parse_diagnostics(roles)
    return {
        "stage": phase,
        "outcome": manifest["outcome"],
        "tool": context.get("toolId"),
        "toolVersion": context.get("toolVersion"),
        "part": context.get("part"),
        "sourceId": context.get("sourceId"),
        "constraintsId": context.get("constraintsId"),
        "clocks": clocks,
        "overallTiming": overall,
        "route": route,
        "drc": drc,
        "manifestId": manifest["manifestId"],
        "timingReport": str(timing.relative_to(root)),
    }


def comparable_metadata(left, right):
    fields = ("stage", "tool", "toolVersion", "part", "sourceId", "constraintsId")
    result = {key: bool(left.get(key)) and bool(right.get(key)) and left[key] == right[key] for key in fields}
    names_match = set(left["clocks"]) == set(right["clocks"]) and bool(left["clocks"])
    result["clockSet"] = names_match
    periods_match = names_match and all(
        left["clocks"][name].get("periodNs") is not None
        and right["clocks"][name].get("periodNs") is not None
        and left["clocks"][name]["periodNs"] == right["clocks"][name]["periodNs"]
        for name in left["clocks"]
    )
    result["clockPeriods"] = periods_match
    required_metrics = ("wnsNs", "tnsNs", "failingEndpoints", "holdWnsNs", "holdTnsNs", "holdFailingEndpoints")
    metrics_present = names_match and all(
        all(left["clocks"][name].get(key) is not None and right["clocks"][name].get(key) is not None
            for key in required_metrics)
        for name in left["clocks"]
    )
    result["clockMetrics"] = metrics_present
    return result


def safe_delta(after, before):
    if isinstance(before, bool) or isinstance(after, bool):
        return None
    if not isinstance(before, (int, float)) or not isinstance(after, (int, float)):
        return None
    if not (Decimal(str(before)).is_finite() and Decimal(str(after)).is_finite()):
        return None
    return after - before


def compare(left, right):
    checks = comparable_metadata(left, right)
    clock_comparison = {}
    metric_names = ("wnsNs", "tnsNs", "failingEndpoints", "holdWnsNs", "holdTnsNs", "holdFailingEndpoints")
    for name in sorted(set(left["clocks"]) | set(right["clocks"])):
        before = left["clocks"].get(name)
        after = right["clocks"].get(name)
        delta = None if before is None or after is None else {
            key: safe_delta(after.get(key), before.get(key)) for key in metric_names
        }
        clock_comparison[name] = {"before": before, "after": after, "delta": delta}
    ok = all(checks.values())
    return {
        "api": "coyote-nix.physical-comparison/v1",
        "comparable": ok,
        "comparability": checks,
        "warning": None if ok else "unknown or mismatched stage/tool/part/source/constraints/clock periods; deltas are descriptive only",
        "before": left,
        "after": right,
        "clockComparison": clock_comparison,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path, help="hash-verified saved stage output directory")
    parser.add_argument("after", type=Path, help="hash-verified saved stage output directory")
    parser.add_argument("--json", type=Path, help="write comparison JSON")
    args = parser.parse_args(argv)
    try:
        result = compare(read_stage(args.before), read_stage(args.after))
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    for label in ("before", "after"):
        item = result[label]
        print(f"{label}: {item['stage']} ({item['outcome']}) tool={item['tool']} part={item['part']} source={item['sourceId']} constraints={item['constraintsId']}")
    print("comparable: " + ("yes" if result["comparable"] else "NO — " + result["warning"]))
    for name, entry in result["clockComparison"].items():
        before = entry["before"]
        after = entry["after"]
        print(f"{name}:")
        for key, label in (
            ("periodNs", "period ns"), ("wnsNs", "setup WNS ns"),
            ("tnsNs", "setup TNS ns"), ("failingEndpoints", "setup failing endpoints"),
            ("holdWnsNs", "hold WNS ns"), ("holdTnsNs", "hold TNS ns"),
            ("holdFailingEndpoints", "hold failing endpoints"),
        ):
            left = None if before is None else before.get(key)
            right = None if after is None else after.get(key)
            print(f"  {label}: {left} -> {right}")
    print(f"route: before={result['before']['route']} after={result['after']['route']}")
    print(f"DRC: before={result['before']['drc']} after={result['after']['drc']}")
    if args.json:
        try:
            args.json.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
        except (OSError, ValueError) as error:
            print(f"ERROR: cannot write comparison: {error}", file=sys.stderr)
            return 2
    return 0 if result["comparable"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
