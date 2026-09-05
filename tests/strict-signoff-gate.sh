#!/usr/bin/env bash
set -euo pipefail

signoff_tool=${1:?strict-signoff tool required}
stage_tool=${2:?implementation-stage tool required}
fixtures=${3:?strict-signoff fixture directory required}
work=${TMPDIR:-/tmp}/strict-signoff-gate
rm -rf "$work"
mkdir -p "$work"

python3 - "$work/context.json" <<'PY'
import hashlib, json, sys
context = {
    "board": "v80",
    "architecture": "versal",
    "part": "xcv80-fixture",
    "flow": "build-app",
    "sourceId": "source-fixture",
    "coyoteSourceId": "coyote-source-fixture",
    "constraintsId": "constraints-fixture",
    "toolId": "vivado-fixture",
    "toolVersion": "2025.1",
}
encoded = json.dumps(context, sort_keys=True, separators=(",", ":")).encode()
context["id"] = hashlib.sha256(encoded).hexdigest()
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(context, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
context_id=$(jq -r .id "$work/context.json")
context=$(jq -cS . "$work/context.json")

previous=
for phase in inputs link place route; do
  stage="$work/$phase"
  mkdir -p "$stage/checkpoints"
  printf '%s checkpoint\n' "$phase" > "$stage/checkpoints/$phase.dcp"
  if [ "$phase" = inputs ]; then
    predecessor=
  else
    predecessor="\"predecessorPath\": \"$previous\","
  fi
  cat > "$work/$phase-spec.json" <<EOF
{"phase":"$phase","unit":"config_0","context":$context,$predecessor"artifacts":[{"role":"$phase-checkpoint","path":"checkpoints/$phase.dcp"}]}
EOF
  python3 "$stage_tool" write "$work/$phase-spec.json" "$stage" "$stage"
  previous=$stage
done

setup_reports() {
  local stage=$1
  mkdir -p "$stage/checkpoints" "$stage/reports"
  printf 'validated checkpoint\n' > "$stage/checkpoints/validated.dcp"
  printf '{"schemaVersion":1,"outcome":"accepted","reasons":[]}\n' \
    > "$stage/reports/validation.json"
  cp "$fixtures/methodology.rpt" "$stage/reports/shell_methodology_c0.rpt"
  cp "$fixtures/timing-exceptions.rpt" "$stage/reports/shell_timing_exceptions_c0.rpt"
  cp "$fixtures/bus-skew.rpt" "$stage/reports/shell_bus_skew_c0.rpt"
  cp "$fixtures/clock-interaction.rpt" "$stage/reports/shell_clock_interaction_c0.rpt"
  cp "$fixtures/unconstrained-endpoints.rpt" "$stage/reports/shell_unconstrained_endpoints_c0.rpt"
  cp "$fixtures/unconstrained-endpoint-evidence.json" \
    "$stage/reports/shell_unconstrained_endpoint_evidence_c0.json"
  cp "$fixtures/drc.rpt" "$stage/reports/shell_drc_c0.rpt"
  cp "$fixtures/timing-summary.rpt" "$stage/reports/shell_timing_summary_c0.rpt"
  cp "$fixtures/route-status.rpt" "$stage/reports/shell_route_status_c0.rpt"
  cp "$fixtures/bitstream-drc.rpt" "$stage/reports/shell_drc_bitstream_checks_c0.rpt"
  cp "$fixtures/physical.json" "$stage/reports/shell_physical_c0.json"
  chmod -R u+w "$stage"
}

collect_evidence() {
  local stage=$1
  python3 "$signoff_tool" collect \
    --root "$stage" \
    --phase validate \
    --unit config_0 \
    --context "$work/context.json" \
    --checkpoint "$stage/checkpoints/validated.dcp" \
    --report-directory reports \
    --report-prefix shell \
    --report-suffix _c0 \
    --output "$stage/reports/shell_strict_signoff_c0.json"
}

expect_collect_rejected() {
  local name=$1
  local stage=$2
  local expected=$3
  if collect_evidence "$stage" >"$work/$name.stdout" 2>"$work/$name.stderr"; then
    echo "strict signoff unexpectedly collected malformed DRC evidence for $name" >&2
    exit 1
  fi
  grep -F -- "$expected" "$work/$name.stderr" >/dev/null
}

make_classification() {
  local stage=$1
  local output=$2
  python3 - "$work/context.json" \
    "$stage/reports/shell_strict_signoff_c0.json" \
    "$fixtures/explicit-classifications.json" \
    "$stage/metadata/stage.json" "$output" <<'PY'
import json, sys
context = json.load(open(sys.argv[1], encoding="utf-8"))
evidence = json.load(open(sys.argv[2], encoding="utf-8"))
explicit = json.load(open(sys.argv[3], encoding="utf-8"))
manifest = json.load(open(sys.argv[4], encoding="utf-8"))
exception = dict(explicit["timingExceptionReport"])
exception["reportSha256"] = evidence["timingExceptionSet"]["reportSha256"]
observed = {
    (entry["category"], entry["endpoint"], entry["reason"]): entry["id"]
    for entry in evidence["unconstrainedEndpoints"]
}
endpoints = []
for entry in explicit["unconstrainedEndpoints"]:
    classified = dict(entry)
    classified["id"] = observed[(entry["category"], entry["endpoint"], entry["reason"])]
    endpoints.append(classified)
document = {
    "schemaVersion": 1,
    "api": "coyote-nix.strict-signoff-classification/v1",
    "contextId": context["id"],
    "subjects": [{
        "unit": "config_0",
        "evidenceId": evidence["evidenceId"],
        "stageManifestId": manifest["manifestId"],
        "artifactIdentity": evidence["artifactIdentity"],
        "sourceIdentity": evidence["sourceIdentity"],
        "timingExceptionReport": exception,
        "unconstrainedEndpoints": endpoints,
    }],
}
with open(sys.argv[5], "w", encoding="utf-8") as stream:
    json.dump(document, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
}

make_policy_classification() {
  local stage=$1
  local output=$2
  python3 - "$work/context.json" \
    "$stage/reports/shell_strict_signoff_c0.json" \
    "$stage/metadata/stage.json" "$output" <<'PY'
import json, sys
context = json.load(open(sys.argv[1], encoding="utf-8"))
evidence = json.load(open(sys.argv[2], encoding="utf-8"))
manifest = json.load(open(sys.argv[3], encoding="utf-8"))
endpoints = []
for observed in evidence["unconstrainedEndpoints"]:
    entry = dict(observed)
    entry["classification"] = "intentional-constant-clock"
    entry["rationale"] = "Exact fixture endpoint classification for rejection coverage."
    endpoints.append(entry)
document = {
    "schemaVersion": 1,
    "api": "coyote-nix.strict-signoff-classification/v1",
    "contextId": context["id"],
    "subjects": [{
        "unit": "config_0",
        "evidenceId": evidence["evidenceId"],
        "stageManifestId": manifest["manifestId"],
        "artifactIdentity": evidence["artifactIdentity"],
        "sourceIdentity": evidence["sourceIdentity"],
        "timingExceptionReport": {
            "reportSha256": evidence["timingExceptionSet"]["reportSha256"],
            "classification": "explicit-exact-report",
            "rationale": "The exact fixture exception report was reviewed.",
        },
        "unconstrainedEndpoints": endpoints,
    }],
}
with open(sys.argv[4], "w", encoding="utf-8") as stream:
    json.dump(document, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
}

make_manifest() {
  local stage=$1
  local omitted_role=${2:-}
  python3 - "$work/context.json" "$work/route" "$stage" "$omitted_role" <<'PY'
import json, os, sys
context = json.load(open(sys.argv[1], encoding="utf-8"))
stage = sys.argv[3]
omitted = sys.argv[4]
artifacts = {
    "validated-checkpoint": "checkpoints/validated.dcp",
    "validation-result": "reports/validation.json",
    "physical-observations": "reports/shell_physical_c0.json",
    "validate-methodology-report": "reports/shell_methodology_c0.rpt",
    "validate-timing-exception-report": "reports/shell_timing_exceptions_c0.rpt",
    "validate-bus-skew-report": "reports/shell_bus_skew_c0.rpt",
    "validate-clock-interaction-report": "reports/shell_clock_interaction_c0.rpt",
    "validate-unconstrained-endpoint-report": "reports/shell_unconstrained_endpoints_c0.rpt",
    "validate-unconstrained-endpoint-evidence": "reports/shell_unconstrained_endpoint_evidence_c0.json",
    "validate-drc-report": "reports/shell_drc_c0.rpt",
    "validate-timing-summary-report": "reports/shell_timing_summary_c0.rpt",
    "validate-route-status-report": "reports/shell_route_status_c0.rpt",
    "bitstream-drc-report": "reports/shell_drc_bitstream_checks_c0.rpt",
    "validate-strict-signoff-evidence": "reports/shell_strict_signoff_c0.json",
}
spec = {
    "phase": "validate",
    "unit": "config_0",
    "context": context,
    "predecessorPath": sys.argv[2],
    "outcomePath": "reports/validation.json",
    "artifacts": [
        {"role": role, "path": path}
        for role, path in artifacts.items()
        if role != omitted
    ],
}
with open(os.path.join(stage, "spec.json"), "w", encoding="utf-8") as stream:
    json.dump(spec, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
  rm -rf "$stage/metadata"
  python3 "$stage_tool" write "$stage/spec.json" "$stage" "$stage"
  python3 "$stage_tool" validate "$stage" --phase validate --context "$context_id"
}

expect_rejected() {
  local name=$1
  local stage=$2
  local classification=$3
  local expected_check=$4
  local result="$work/$name-result.json"
  args=(
    verify --stage "$stage" --context "$context_id" --output "$result"
  )
  if [ "$classification" != - ]; then
    args+=(--classification "$classification")
  fi
  if python3 "$signoff_tool" "${args[@]}"; then
    echo "strict signoff unexpectedly accepted $name" >&2
    exit 1
  fi
  jq -e --arg check "$expected_check" \
    '.outcome == "rejected" and (.failedChecks | index($check)) != null' \
    "$result" >/dev/null
}

accepted="$work/accepted"
setup_reports "$accepted"
collect_evidence "$accepted"
make_manifest "$accepted"
make_classification "$accepted" "$work/accepted-classification.json"
python3 "$signoff_tool" verify \
  --stage "$accepted" \
  --context "$context_id" \
  --classification "$work/accepted-classification.json" \
  --output "$work/accepted-result.json"
jq -e '
  .outcome == "accepted"
  and .failedChecks == []
  and (.stageManifestId | test("^[0-9a-f]{64}$"))
  and (.evidenceId | test("^[0-9a-f]{64}$"))
  and (.artifactIdentity.sha256 | test("^[0-9a-f]{64}$"))
  and .sourceIdentity.sourceId == "source-fixture"
  and .sourceIdentity.coyoteSourceId == "coyote-source-fixture"
  and (.classificationSha256 | test("^[0-9a-f]{64}$"))
' "$work/accepted-result.json" >/dev/null

tampered="$work/tampered-report-artifact"
cp -a "$accepted" "$tampered"
printf '\npost-manifest tamper\n' >> "$tampered/reports/shell_timing_summary_c0.rpt"
expect_rejected tampered-report-artifact "$tampered" \
  "$work/accepted-classification.json" stage

missing="$work/missing-report"
cp -a "$accepted" "$missing"
rm "$missing/reports/shell_methodology_c0.rpt"
make_manifest "$missing" validate-methodology-report
expect_rejected missing-report "$missing" "$work/accepted-classification.json" reports

malformed="$work/malformed-report"
cp -a "$accepted" "$malformed"
printf 'not a methodology report\n' > "$malformed/reports/shell_methodology_c0.rpt"
make_manifest "$malformed"
expect_rejected malformed-report "$malformed" "$work/accepted-classification.json" reports

for metric in setupWnsNs setupTnsNs holdWnsNs holdTnsNs; do
  name="negative-$metric"
  stage="$work/$name"
  cp -a "$accepted" "$stage"
  python3 - "$stage/reports/shell_physical_c0.json" \
    "$stage/reports/shell_timing_summary_c0.rpt" "$metric" <<'PY'
import json, sys
physical_path, timing_path, metric = sys.argv[1:]
physical = json.load(open(physical_path, encoding="utf-8"))
physical["timing"][metric] = -0.125
with open(physical_path, "w", encoding="utf-8") as stream:
    json.dump(physical, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
lines = open(timing_path, encoding="utf-8").read().splitlines()
metric_index = {
    "setupWnsNs": 0,
    "setupTnsNs": 1,
    "holdWnsNs": 4,
    "holdTnsNs": 5,
}[metric]
for index, line in enumerate(lines):
    fields = line.split()
    if len(fields) >= 8 and fields[0] == "0.125" and fields[4] == "0.050":
        fields[metric_index] = "-0.125"
        lines[index] = " ".join(fields)
        break
else:
    raise SystemExit("fixture timing row not found")
open(timing_path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
  collect_evidence "$stage"
  make_manifest "$stage"
  make_classification "$stage" "$work/$name-classification.json"
  expect_rejected "$name" "$stage" "$work/$name-classification.json" timing
done

route_failure="$work/route-failure"
cp -a "$accepted" "$route_failure"
python3 - "$route_failure/reports/shell_physical_c0.json" \
  "$route_failure/reports/shell_route_status_c0.rpt" <<'PY'
import json, sys
physical = json.load(open(sys.argv[1], encoding="utf-8"))
physical["routing"]["unroutedNets"] = 1
physical["routing"]["hasRoutingErrors"] = 1
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(physical, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
text = open(sys.argv[2], encoding="utf-8").read()
text = text.replace("# of fully routed nets............. :          10", "# of fully routed nets............. :           9")
text = text.replace("# of nets with routing errors.......... :           0", "# of nets with routing errors.......... :           1")
open(sys.argv[2], "w", encoding="utf-8").write(text)
PY
collect_evidence "$route_failure"
make_manifest "$route_failure"
make_classification "$route_failure" "$work/route-failure-classification.json"
expect_rejected route-failure "$route_failure" "$work/route-failure-classification.json" routing

drc_failure="$work/drc-failure"
cp -a "$accepted" "$drc_failure"
cat > "$drc_failure/reports/shell_drc_c0.rpt" <<'EOF'
| Command : report_drc -name fixture_signoff -file drc.rpt
Report DRC
Checks found: 1
| Rule       | Severity | Description     | Checks |
| ROUTE-FAIL | Error    | Fixture failure | 1      |
EOF
collect_evidence "$drc_failure"
make_manifest "$drc_failure"
make_classification "$drc_failure" "$work/drc-failure-classification.json"
expect_rejected drc-failure "$drc_failure" "$work/drc-failure-classification.json" drc

real_vivado_drc_failure="$work/real-vivado-drc-failure"
cp -a "$accepted" "$real_vivado_drc_failure"
cp "$fixtures/vivado-2023.2-u280-drc-violations.rpt" \
  "$real_vivado_drc_failure/reports/shell_drc_c0.rpt"
collect_evidence "$real_vivado_drc_failure"
jq -e '
  .drc.implementation.checks == 266
  and .drc.implementation.errors == 0
  and .drc.implementation.criticalWarnings == 2
  and .drc.implementation.warnings == 261
' "$real_vivado_drc_failure/reports/shell_strict_signoff_c0.json" >/dev/null
make_manifest "$real_vivado_drc_failure"
make_classification "$real_vivado_drc_failure" \
  "$work/real-vivado-drc-failure-classification.json"
expect_rejected real-vivado-drc-failure "$real_vivado_drc_failure" \
  "$work/real-vivado-drc-failure-classification.json" drc

violations_drc_mismatch="$work/violations-drc-mismatch"
cp -a "$accepted" "$violations_drc_mismatch"
cat > "$violations_drc_mismatch/reports/shell_drc_c0.rpt" <<'EOF'
| Command : report_drc -name fixture_signoff -file drc.rpt
Report DRC
Violations found: 2
+------+----------+-----------------+------------+
| Rule | Severity | Description     | Violations |
+------+----------+-----------------+------------+
| BAD  | Error    | Fixture failure | 1          |
+------+----------+-----------------+------------+
EOF
expect_collect_rejected violations-drc-mismatch "$violations_drc_mismatch" \
  "implementation DRC report summary does not account for every DRC violation"

unknown_drc_severity="$work/unknown-drc-severity"
cp -a "$accepted" "$unknown_drc_severity"
cat > "$unknown_drc_severity/reports/shell_drc_c0.rpt" <<'EOF'
| Command : report_drc -name fixture_signoff -file drc.rpt
Report DRC
Violations found: 1
+------+----------+-----------------+------------+
| Rule | Severity | Description     | Violations |
+------+----------+-----------------+------------+
| BAD  | Notice   | Fixture failure | 1          |
+------+----------+-----------------+------------+
EOF
expect_collect_rejected unknown-drc-severity "$unknown_drc_severity" \
  "implementation DRC report contains an unknown DRC severity: Notice"

ambiguous_drc_summary="$work/ambiguous-drc-summary"
cp -a "$accepted" "$ambiguous_drc_summary"
cat > "$ambiguous_drc_summary/reports/shell_drc_c0.rpt" <<'EOF'
| Command : report_drc -name fixture_signoff -file drc.rpt
Report DRC
Checks found: 0
Violations found: 0
+------+----------+-------------+--------+
| Rule | Severity | Description | Checks |
+------+----------+-------------+--------+
+------+----------+-------------+--------+
EOF
expect_collect_rejected ambiguous-drc-summary "$ambiguous_drc_summary" \
  "implementation DRC report requires exactly one supported DRC summary count"

bitstream_drc_failure="$work/bitstream-drc-failure"
cp -a "$accepted" "$bitstream_drc_failure"
cat > "$bitstream_drc_failure/reports/shell_drc_bitstream_checks_c0.rpt" <<'EOF'
| Command : report_drc -ruledeck bitstream_checks -file bitstream-drc.rpt
Report DRC
Checks found: 1
| Rule       | Severity         | Description     | Checks |
| ROUTE-FAIL | Critical Warning | Fixture failure | 1      |
EOF
python3 - "$bitstream_drc_failure/reports/shell_physical_c0.json" <<'PY'
import json, sys
path = sys.argv[1]
physical = json.load(open(path, encoding="utf-8"))
physical["drc"]["criticalWarnings"] = 1
with open(path, "w", encoding="utf-8") as stream:
    json.dump(physical, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
collect_evidence "$bitstream_drc_failure"
make_manifest "$bitstream_drc_failure"
make_classification "$bitstream_drc_failure" \
  "$work/bitstream-drc-failure-classification.json"
expect_rejected bitstream-drc-failure "$bitstream_drc_failure" \
  "$work/bitstream-drc-failure-classification.json" drc

expect_rejected missing-classification "$accepted" - classification

cp "$work/accepted-classification.json" "$work/stale-classification.json"
python3 - "$work/stale-classification.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["subjects"][0]["evidenceId"] = "0" * 64
json.dump(data, open(path, "w", encoding="utf-8"), sort_keys=True, separators=(",", ":"))
PY
expect_rejected stale-classification "$accepted" "$work/stale-classification.json" classification

for identity in stage artifact source; do
  classification="$work/stale-$identity-identity.json"
  cp "$work/accepted-classification.json" "$classification"
  python3 - "$classification" "$identity" <<'PY'
import json, sys
path, identity = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
subject = data["subjects"][0]
if identity == "stage":
    subject["stageManifestId"] = "1" * 64
elif identity == "artifact":
    subject["artifactIdentity"]["sha256"] = "2" * 64
else:
    subject["sourceIdentity"]["sourceId"] = "stale-source"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
  expect_rejected "stale-$identity-identity" "$accepted" "$classification" classification
done

cp "$work/accepted-classification.json" "$work/mismatched-exception-classification.json"
python3 - "$work/mismatched-exception-classification.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["subjects"][0]["timingExceptionReport"]["reportSha256"] = "f" * 64
json.dump(data, open(path, "w", encoding="utf-8"), sort_keys=True, separators=(",", ":"))
PY
expect_rejected mismatched-exception "$accepted" \
  "$work/mismatched-exception-classification.json" classification

cp "$work/accepted-classification.json" "$work/unclassified-endpoint.json"
python3 - "$work/unclassified-endpoint.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["subjects"][0]["unconstrainedEndpoints"] = []
json.dump(data, open(path, "w", encoding="utf-8"), sort_keys=True, separators=(",", ":"))
PY
expect_rejected unclassified-endpoint "$accepted" \
  "$work/unclassified-endpoint.json" classification

for mutation in classification clock; do
  path="$work/mismatched-endpoint-$mutation.json"
  cp "$work/accepted-classification.json" "$path"
  python3 - "$path" "$mutation" <<'PY'
import json, sys
path, mutation = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
endpoint = data["subjects"][0]["unconstrainedEndpoints"][0]
if mutation == "classification":
    endpoint["classification"] = "reviewed-unconstrained-endpoint"
else:
    endpoint["clockPins"][0]["constantValue"] = "1"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
  expect_rejected "mismatched-endpoint-$mutation" "$accepted" "$path" classification
done

for endpoint_case in no-clock missing-max-delay constant-without-clock-evidence; do
  stage="$work/$endpoint_case"
  cp -a "$accepted" "$stage"
  python3 - "$stage/reports/shell_unconstrained_endpoints_c0.rpt" \
    "$stage/reports/shell_unconstrained_endpoint_evidence_c0.json" \
    "$endpoint_case" <<'PY'
import json, sys
report_path, evidence_path, endpoint_case = sys.argv[1:]
if endpoint_case == "no-clock":
    category = "no_clock"
    endpoint = "fixture/unclocked_reg[0]/C"
    reason = "no-clock"
    clock_pins = [{"pin": endpoint, "constantValue": "", "clocks": []}]
    no_clock_count = 1
    unconstrained_count = 0
    no_clock_detail = f" There are 1 register/latch pins with no clock.\n{endpoint}\n"
    unconstrained_detail = (
        " There are 0 pins that are not constrained for maximum delay.\n\n"
        " There are 0 pins that are not constrained for maximum delay due to constant clock.\n"
    )
elif endpoint_case == "missing-max-delay":
    category = "unconstrained_internal_endpoints"
    endpoint = "fixture/unconstrained_reg[0]/D"
    reason = "missing-max-delay"
    clock_pins = [{
        "pin": "fixture/unconstrained_reg[0]/C",
        "constantValue": "",
        "clocks": ["fixture_clock"],
    }]
    no_clock_count = 0
    unconstrained_count = 1
    no_clock_detail = " There are 0 register/latch pins with no clock.\n"
    unconstrained_detail = (
        " There are 1 pins that are not constrained for maximum delay. (HIGH)\n"
        f"{endpoint}\n\n"
        " There are 0 pins that are not constrained for maximum delay due to constant clock.\n"
    )
else:
    category = "unconstrained_internal_endpoints"
    endpoint = "fixture/disabled_counter_reg[0]/D"
    reason = "constant-clock"
    clock_pins = [{
        "pin": "fixture/disabled_counter_reg[0]/C",
        "constantValue": "",
        "clocks": [],
    }]
    no_clock_count = 0
    unconstrained_count = 1
    no_clock_detail = " There are 0 register/latch pins with no clock.\n"
    unconstrained_detail = (
        " There are 0 pins that are not constrained for maximum delay.\n\n"
        " There are 1 pins that are not constrained for maximum delay due to constant clock. (MEDIUM)\n"
        f"{endpoint}\n"
    )
report = f"""| Command : check_timing -verbose -file unconstrained_endpoints.rpt

check_timing report

Table of Contents
-----------------
1. checking no_clock ({no_clock_count})
2. checking unconstrained_internal_endpoints ({unconstrained_count})

1. checking no_clock ({no_clock_count})
------------------------
{no_clock_detail}
2. checking unconstrained_internal_endpoints ({unconstrained_count})
------------------------------------------------
{unconstrained_detail}"""
open(report_path, "w", encoding="utf-8").write(report)
document = {
    "schemaVersion": 1,
    "api": "coyote-nix.strict-signoff-endpoints/v1",
    "endpoints": [{
        "category": category,
        "endpoint": endpoint,
        "reason": reason,
        "clockPins": clock_pins,
    }],
}
with open(evidence_path, "w", encoding="utf-8") as stream:
    json.dump(document, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
  collect_evidence "$stage"
  make_manifest "$stage"
  make_policy_classification "$stage" "$work/$endpoint_case-classification.json"
  expect_rejected "$endpoint_case" "$stage" \
    "$work/$endpoint_case-classification.json" classification
done

printf 'strict signoff gate contract: PASS\n'
