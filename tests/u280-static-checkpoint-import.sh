#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <import-tool>" >&2
  exit 2
fi

tool=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
mkdir -p "$stage/checkpoints" "$stage/reports" "$stage/metadata"

python3 - "$tool" "$stage" <<'PY'
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

tool = Path(sys.argv[1])
stage = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("implementation_stage", tool.with_name("coyote-implementation-stage.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

files = {
    "checkpoints/shell_routed.dcp": b"immutable routed shell checkpoint\n",
    "reports/shell_timing_summary.rpt": b"timing constraints met\n",
    "reports/shell_route_status.rpt": b"""Design Route Status
 # of routable nets............................. :          12 :
 # of nets with fixed routing................... :           7 :
 # of fully routed nets......................... :          12 :
 # of nets with routing errors.................. :           0 :
""",
    "reports/shell_drc_bitstream_checks.rpt": b"zero errors\n",
    "reports/validation.json": b'{"outcome":"accepted","reasons":[],"schemaVersion":1}\n',
    "reports/shell_physical.json": b'{"analysisKind":"routed","drc":{"criticalWarnings":0,"errors":0,"warnings":2},"kind":"coyote-implementation-observations","phase":"validate","reports":{"routeStatus":"shell_route_status.rpt","timingSummary":"shell_timing_summary.rpt"},"routing":{"conflictedNets":0,"hasRoutingErrors":0,"partiallyRoutedNets":0,"unroutedNets":0},"schemaVersion":1,"timing":{"holdTnsNs":0.0,"holdWnsNs":0.006,"setupTnsNs":0.0,"setupWnsNs":0.026},"vivadoVersion":"2023.2"}\n',
}
for relative, content in files.items():
    path = stage / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)

context_without_id = {
    "architecture": "ultrascale_plus",
    "board": "u280",
    "constraintsId": "1" * 64,
    "coyoteSourceId": "2" * 64,
    "flow": "build-shell",
    "part": "xcu280-fsvh2892-2L-e",
    "sourceId": "3" * 64,
    "toolId": "vivado-2023.2@fixture",
    "toolVersion": "2023.2",
    "topology": {"configurations": 1, "regions": 1},
}
context = dict(context_without_id)
context["id"] = hashlib.sha256(module.canonical(context_without_id).rstrip(b"\n")).hexdigest()
roles = {
    "checkpoints/shell_routed.dcp": "validated-checkpoint",
    "reports/shell_timing_summary.rpt": "validate-timing-summary-report",
    "reports/shell_route_status.rpt": "validate-route-status-report",
    "reports/shell_drc_bitstream_checks.rpt": "bitstream-drc-report",
    "reports/validation.json": "validation-result",
    "reports/shell_physical.json": "physical-observations",
}
artifacts = []
for relative, role in roles.items():
    path = stage / relative
    artifacts.append({
        "path": relative,
        "role": role,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "size": path.stat().st_size,
    })
manifest = {
    "api": "coyote-nix.implementation-stage/v1",
    "artifacts": artifacts,
    "context": context,
    "outcome": "accepted",
    "phase": "validate",
    "predecessor": {
        "contextId": context["id"],
        "manifestId": "4" * 64,
        "outcome": "complete",
        "phase": "route",
        "unit": "shell",
    },
    "resources": {"cores": 1},
    "schemaVersion": 1,
    "strategy": {},
    "unit": "shell",
}
manifest["manifestId"] = hashlib.sha256(module.canonical(manifest)).hexdigest()
(stage / "metadata/stage.json").write_bytes(module.canonical(manifest))
(stage / "metadata/complete").write_text(manifest["manifestId"] + "\n", encoding="utf-8")
(stage.parent / "manifest-id").write_text(manifest["manifestId"], encoding="utf-8")
(stage.parent / "checkpoint-sha256").write_text(artifacts[0]["sha256"], encoding="utf-8")
PY

manifest_id=$(<"$work/manifest-id")
checkpoint_sha256=$(<"$work/checkpoint-sha256")
common=(
  "$stage"
  --manifest-id "$manifest_id"
  --checkpoint-sha256 "$checkpoint_sha256"
  --coyote-source-id "$(printf '2%.0s' {1..64})"
  --fixed-route-nets 7
  --tool-version 2023.2
)

python3 "$tool" "${common[@]:0:1}" "$work/imported" "${common[@]:1}"
cmp "$stage/checkpoints/shell_routed.dcp" "$work/imported/checkpoints/static_routed_locked_u280.dcp"
jq -e '
  .api == "coyote-nix.u280-static-checkpoint/v1"
  and .compatibility.board == "u280"
  and .protectedStatic.lockLevel == "routing"
  and .protectedStatic.fixedRouteNets == 7
  and .applicationLink.partitionPins == "preserve-from-validated-checkpoint"
  and .applicationLink.protectedStatic == "reject-drift"
  and ([.reports[].sha256 | test("^[0-9a-f]{64}$")] | all)
' "$work/imported/metadata/static-checkpoint.json" >/dev/null

after_tamper="$work/tampered"
cp -a "$stage" "$after_tamper"
printf 'tamper\n' >> "$after_tamper/reports/shell_timing_summary.rpt"
if python3 "$tool" "$after_tamper" "$work/rejected-tamper" "${common[@]:1}" >/dev/null 2>&1; then
  echo "tampered hashed report was accepted" >&2
  exit 1
fi
if python3 "$tool" "$stage" "$work/rejected-board" "${common[@]:1}" --board v80 >/dev/null 2>&1; then
  echo "incompatible board was accepted" >&2
  exit 1
fi
if python3 "$tool" "$stage" "$work/rejected-lock" \
  --manifest-id "$manifest_id" \
  --checkpoint-sha256 "$checkpoint_sha256" \
  --coyote-source-id "$(printf '2%.0s' {1..64})" \
  --fixed-route-nets 8 \
  --tool-version 2023.2 >/dev/null 2>&1; then
  echo "changed fixed-route lock count was accepted" >&2
  exit 1
fi
