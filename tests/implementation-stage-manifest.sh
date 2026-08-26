#!/usr/bin/env bash
set -euo pipefail

tool=${1:?implementation-stage tool required}
fixtures=${2:?Vivado report fixture directory required}
incremental_tool=${3:?incremental-reference tool required}
work=${TMPDIR:-/tmp}/implementation-stage-contract
rm -rf "$work"
mkdir -p "$work"

expect_failure() {
  if "$@"; then
    echo "unexpected success: $*" >&2
    exit 1
  fi
}

context_without_id='{"board":"v80","architecture":"versal","part":"xcv80","flow":"app","sourceId":"source-fixture","constraintsId":"constraints-fixture","toolId":"site-fixture","toolVersion":"2025.1"}'
context=$(python3 - "$context_without_id" <<'PY'
import hashlib, json, sys
value = json.loads(sys.argv[1])
encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
value["id"] = hashlib.sha256(encoded).hexdigest()
print(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
)
context_id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$context")

make_spec() {
  phase=$1
  predecessor=$2
  artifact=$3
  cat <<EOF
{
  "phase": "$phase",
  "unit": "config_0",
  "context": $context,
  "strategy": {"directive": "fixture"},
  "resources": {"cores": 8},
  $predecessor
  "artifacts": [{"role":"${phase}-checkpoint","path":"checkpoints/$artifact"}]
}
EOF
}

mkdir -p "$work/inputs/checkpoints"
printf 'synthesis bundle\n' > "$work/inputs/checkpoints/inputs.dcp"
make_spec inputs '' inputs.dcp > "$work/inputs.json"
python3 "$tool" write "$work/inputs.json" "$work/inputs" "$work/inputs"
python3 "$tool" validate "$work/inputs" --phase inputs --context "$context_id"
for variant in a b; do
  mkdir -p "$work/v2-input-$variant/checkpoints"
  printf 'synthesis bundle %s\n' "$variant" > "$work/v2-input-$variant/checkpoints/inputs.dcp"
  cat > "$work/v2-input-$variant.json" <<EOF
{"schemaVersion":2,"phase":"inputs","unit":"config_0","context":$context,"strategy":{},"resources":{"cores":8},"artifacts":[{"role":"inputs-checkpoint","path":"checkpoints/inputs.dcp"}]}
EOF
  python3 "$tool" write "$work/v2-input-$variant.json" "$work/v2-input-$variant" "$work/v2-input-$variant"
done
test "$(jq -r .recipeId "$work/v2-input-a/metadata/stage.json")" = \
  "$(jq -r .recipeId "$work/v2-input-b/metadata/stage.json")"
test "$(jq -r .manifestId "$work/v2-input-a/metadata/stage.json")" != \
  "$(jq -r .manifestId "$work/v2-input-b/metadata/stage.json")"

previous=$work/inputs
for phase in link opt place route; do
  stage=$work/$phase
  mkdir -p "$stage/checkpoints"
  printf '%s checkpoint\n' "$phase" > "$stage/checkpoints/$phase.dcp"
  make_spec "$phase" "\"predecessorPath\": \"$previous\"," "$phase.dcp" > "$work/$phase.json"
  python3 "$tool" write "$work/$phase.json" "$stage" "$stage"
  python3 "$tool" validate "$stage" --phase "$phase" --context "$context_id"
  previous=$stage
done

mkdir -p "$work/validate/checkpoints" "$work/validate/reports"
printf 'validate checkpoint\n' > "$work/validate/checkpoints/validate.dcp"
printf '{"outcome":"accepted","reasons":[]}\n' > "$work/validate/reports/validation.json"
cat > "$work/validate.json" <<EOF
{"phase":"validate","unit":"config_0","context":$context,"predecessorPath":"$work/route","outcomePath":"reports/validation.json","artifacts":[{"role":"validated-checkpoint","path":"checkpoints/validate.dcp"},{"role":"validation-result","path":"reports/validation.json"}]}
EOF
python3 "$tool" write "$work/validate.json" "$work/validate" "$work/validate"
python3 "$tool" validate "$work/validate" --phase validate --context "$context_id"

u280_context_without_id='{"board":"u280","architecture":"ultrascale_plus","part":"xcu280","flow":"build-app","topology":{"configurations":1,"regions":1},"sourceId":"source-u280","constraintsId":"constraints-u280","toolId":"vivado-2023.2@fixture","toolVersion":"2023.2"}'
u280_context=$(python3 - "$u280_context_without_id" <<'PY'
import hashlib, json, sys
value = json.loads(sys.argv[1])
encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
value["id"] = hashlib.sha256(encoded).hexdigest()
print(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
)
u280_previous=""
for phase in inputs link opt place route validate; do
  stage="$work/u280-$phase"
  mkdir -p "$stage/checkpoints" "$stage/reports"
  printf '%s checkpoint\n' "$phase" > "$stage/checkpoints/$phase.dcp"
  if [ "$phase" = inputs ]; then
    predecessor=''
    artifacts='[{"role":"inputs-checkpoint","path":"checkpoints/inputs.dcp"}]'
    outcome='"complete"'
  else
    predecessor="\"predecessorPath\": \"$u280_previous\","
    artifacts="[{\"role\":\"$phase-checkpoint\",\"path\":\"checkpoints/$phase.dcp\"}]"
    outcome='"complete"'
  fi
  if [ "$phase" = validate ]; then
    printf '{"outcome":"accepted","reasons":[]}\n' > "$stage/reports/validation.json"
    artifacts='[{"role":"validated-checkpoint","path":"checkpoints/validate.dcp"},{"role":"validation-result","path":"reports/validation.json"}]'
    outcome='"accepted"'
  fi
  cat > "$work/u280-$phase.json" <<EOF
{"phase":"$phase","unit":"config_0","context":$u280_context,$predecessor"outcome":$outcome,"artifacts":$artifacts}
EOF
  python3 "$tool" write "$work/u280-$phase.json" "$stage" "$stage"
  u280_previous=$stage
done
printf '%s\n' "$u280_context" > "$work/u280-current-context.json"
python3 "$incremental_tool" "$tool" \
  "$work/u280-validate" "$work/u280-current-context.json" "$work/incremental-reference.json"
jq -e '
  .api == "coyote-nix.incremental-reference/v1"
  and .selection == "explicit"
  and .reference.outcome == "accepted"
  and .reference.checkpoint.role == "validated-checkpoint"
  and .compatibility.board == "u280"
  and .signoffAuthority == false
' "$work/incremental-reference.json" >/dev/null
expect_failure python3 "$incremental_tool" "$tool" \
  "$work/validate" "$work/u280-current-context.json" "$work/wrong-board-reference.json"
printf '%s\n' "$context" > "$work/v80-current-context.json"
expect_failure python3 "$incremental_tool" "$tool" \
  "$work/u280-validate" "$work/v80-current-context.json" "$work/v80-reference.json"

mkdir -p "$work/telemetry-opt/checkpoints" "$work/telemetry-opt/logs" "$work/telemetry-opt/metadata" "$work/telemetry-opt/reports"
printf 'telemetry checkpoint\n' > "$work/telemetry-opt/checkpoints/opt.dcp"
printf 'stdout evidence\n' > "$work/telemetry-opt/logs/command.stdout.log"
printf 'stderr evidence\n' > "$work/telemetry-opt/logs/command.stderr.log"
cp "$fixtures/vivado-2025.1-v80-utilization.rpt" \
  "$work/telemetry-opt/reports/opt-utilization.rpt"
chmod u+w "$work/telemetry-opt/reports/opt-utilization.rpt"
python3 "$tool" parse-utilization \
  "$fixtures/vivado-2023.2-u280-utilization.rpt" > "$work/u280-utilization.json"
jq -e '
  .lut.used == 12345
  and .register.used == 23456
  and .bramTiles.used == 321500
  and .dsp.available == 9024
' "$work/u280-utilization.json" >/dev/null
printf 'timing evidence\n' > "$work/telemetry-opt/reports/opt-timing.rpt"
printf 'qor evidence\n' > "$work/telemetry-opt/reports/opt-qor.rpt"
cat > "$work/telemetry-opt/metadata/gnu-time.txt" <<'EOF'
wallSeconds=12.50
userCpuSeconds=20.25
systemCpuSeconds=1.75
maxRssKiB=1024
exitCode=0
EOF
cat > "$work/telemetry-opt/metadata/execution.json" <<'EOF'
{"schemaVersion":1,"kind":"coyote-stage-execution","measurementScope":"build-commands","status":"completed","exitCode":0,"wallSeconds":"12.50","userCpuSeconds":"20.25","systemCpuSeconds":"1.75","maxRssKiB":1024,"requestedCores":8,"scratchBytesAfterCommand":4096}
EOF
cat > "$work/telemetry-opt/reports/physical.json" <<'EOF'
{"schemaVersion":1,"kind":"coyote-implementation-observations","phase":"opt","vivadoVersion":"2025.1","vivadoFullVersion":"Vivado v2025.1 Build fixture","analysisKind":"estimated","timing":{"setupWnsNs":-0.125,"setupTnsNs":-2.5,"holdWnsNs":0.25,"holdTnsNs":0},"qor":{"rqaScore":3},"routing":{"unroutedNets":null,"partiallyRoutedNets":null,"conflictedNets":null,"hasRoutingErrors":null},"drc":{"errors":null,"criticalWarnings":null,"warnings":null},"reports":{"utilization":"opt-utilization.rpt","timingSummary":"opt-timing.rpt","qorAssessment":"opt-qor.rpt","routeStatus":""}}
EOF
cat > "$work/telemetry-opt.json" <<EOF
{"schemaVersion":2,"phase":"opt","unit":"config_0","context":$context,"predecessorPath":"$work/link","strategy":{"directive":"fixture"},"resources":{"cores":8},"telemetry":{"path":"metadata/telemetry.json","executionPath":"metadata/execution.json","physicalPath":"reports/physical.json"},"artifacts":[{"role":"optimized-checkpoint","path":"checkpoints/opt.dcp"},{"role":"execution-evidence","path":"metadata/execution.json"},{"role":"raw-resource-measurement","path":"metadata/gnu-time.txt"},{"role":"command-stdout","path":"logs/command.stdout.log"},{"role":"command-stderr","path":"logs/command.stderr.log"},{"role":"physical-observations","path":"reports/physical.json"},{"role":"opt-utilization-report","path":"reports/opt-utilization.rpt"},{"role":"opt-timing-summary-report","path":"reports/opt-timing.rpt"},{"role":"opt-qor-assessment-report","path":"reports/opt-qor.rpt"},{"role":"normalized-telemetry","path":"metadata/telemetry.json"}]}
EOF
python3 "$tool" write "$work/telemetry-opt.json" "$work/telemetry-opt" "$work/telemetry-opt"
python3 "$tool" validate "$work/telemetry-opt" --phase opt --context "$context_id"
jq -e '.schemaVersion == 2 and .api == "coyote-nix.implementation-stage/v2" and (.recipeId | test("^[0-9a-f]{64}$"))' \
  "$work/telemetry-opt/metadata/stage.json" >/dev/null
jq -e '
  .api == "coyote-nix.implementation-telemetry/v1"
  and .execution.measurementScope == "build-commands"
  and .metrics.runtime.wallNs.value == 12500000000
  and .metrics.runtime.peakRssBytes.value == 1048576
  and .metrics.physical.timing.setupWnsFs.value == -125000
  and .metrics.physical.timing.holdTnsFs.value == 0
  and .metrics.physical.qor.rqaScore.value == 3
  and .metrics.physical.utilization.lut.used.value == 1234
  and .metrics.physical.utilization.bramTiles.used.value == 12500
  and .metrics.physical.routing.unroutedNets.state == "unavailable"
  and .metrics.physical.routing.unroutedNets.reason == "not-applicable"
' "$work/telemetry-opt/metadata/telemetry.json" >/dev/null

cp -a "$work/telemetry-opt" "$work/telemetry-repeat"
sed -i 's/12.50/13.50/' "$work/telemetry-repeat/metadata/execution.json"
sed -i 's/wallSeconds=12.50/wallSeconds=13.50/' "$work/telemetry-repeat/metadata/gnu-time.txt"
python3 "$tool" write "$work/telemetry-opt.json" "$work/telemetry-repeat" "$work/telemetry-repeat"
test "$(jq -r .recipeId "$work/telemetry-opt/metadata/stage.json")" = \
  "$(jq -r .recipeId "$work/telemetry-repeat/metadata/stage.json")"
test "$(jq -r .manifestId "$work/telemetry-opt/metadata/stage.json")" != \
  "$(jq -r .manifestId "$work/telemetry-repeat/metadata/stage.json")"

cp -a "$work/telemetry-opt" "$work/telemetry-tampered"
printf 'changed\n' >> "$work/telemetry-tampered/logs/command.stdout.log"
expect_failure python3 "$tool" validate "$work/telemetry-tampered"

cp "$work/telemetry-opt/metadata/execution.json" "$work/nonfinite-execution.json"
python3 - "$work/nonfinite-execution.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data['wallSeconds'] = 'NaN'
json.dump(data, open(path, 'w'))
PY
cp "$work/nonfinite-execution.json" "$work/telemetry-opt/metadata/execution.json"
expect_failure python3 "$tool" write "$work/telemetry-opt.json" "$work/telemetry-opt" "$work/telemetry-opt"
cp "$work/telemetry-tampered/metadata/execution.json" "$work/telemetry-opt/metadata/execution.json"
printf 'truncated utilization report\n' > "$work/telemetry-opt/reports/opt-utilization.rpt"
expect_failure python3 "$tool" write "$work/telemetry-opt.json" "$work/telemetry-opt" "$work/telemetry-opt"

mkdir -p "$work/imported"
printf 'poison\n' > "$work/validate/checkpoints/undeclared.dcp"
python3 "$tool" import "$work/validate" "$work/imported" validated-checkpoint
test -f "$work/imported/checkpoints/validate.dcp"
test ! -e "$work/imported/checkpoints/undeclared.dcp"

cp -a "$work/validate" "$work/tampered"
printf 'changed\n' >> "$work/tampered/checkpoints/validate.dcp"
expect_failure python3 "$tool" validate "$work/tampered"

cp -a "$work/validate" "$work/stale-completion"
printf 'wrong\n' > "$work/stale-completion/metadata/complete"
expect_failure python3 "$tool" validate "$work/stale-completion"

cp -a "$work/validate" "$work/context-tamper"
python3 - "$work/context-tamper/metadata/stage.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data['context']['board'] = 'u280'
json.dump(data, open(path, 'w'))
PY
expect_failure python3 "$tool" validate "$work/context-tamper"

cp -a "$work/validate" "$work/stale-manifest"
python3 - "$work/stale-manifest/metadata/stage.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data['resources']['cores'] = 99
json.dump(data, open(path, 'w'))
PY
expect_failure python3 "$tool" validate "$work/stale-manifest"

mkdir -p "$work/illegal/checkpoints"
printf 'illegal\n' > "$work/illegal/checkpoints/illegal.dcp"
make_spec route "\"predecessorPath\": \"$work/link\"," "illegal.dcp" > "$work/illegal.json"
expect_failure python3 "$tool" write "$work/illegal.json" "$work/illegal" "$work/illegal"
cat > "$work/missing-v2-telemetry.json" <<EOF
{"schemaVersion":2,"phase":"opt","unit":"config_0","context":$context,"predecessorPath":"$work/link","artifacts":[{"role":"optimized-checkpoint","path":"checkpoints/opt.dcp"}]}
EOF
expect_failure python3 "$tool" write "$work/missing-v2-telemetry.json" "$work/telemetry-opt" "$work/telemetry-opt"

mkdir -p "$work/rejected/checkpoints" "$work/rejected/reports" "$work/rejected/logs" "$work/rejected/metadata"
printf 'rejected checkpoint\n' > "$work/rejected/checkpoints/rejected.dcp"
printf '{"outcome":"rejected","reasons":["fixture"]}\n' > "$work/rejected/reports/validation.json"
cp "$work/telemetry-tampered/reports/opt-utilization.rpt" "$work/rejected/reports/validate-utilization.rpt"
printf 'timing evidence\n' > "$work/rejected/reports/validate-timing.rpt"
printf 'route evidence\n' > "$work/rejected/reports/validate-route.rpt"
printf 'drc evidence\n' > "$work/rejected/reports/validate-drc.rpt"
printf 'stdout evidence\n' > "$work/rejected/logs/command.stdout.log"
printf 'stderr evidence\n' > "$work/rejected/logs/command.stderr.log"
cp "$work/telemetry-tampered/metadata/execution.json" "$work/rejected/metadata/execution.json"
cp "$work/telemetry-tampered/metadata/gnu-time.txt" "$work/rejected/metadata/gnu-time.txt"
cat > "$work/rejected/reports/physical.json" <<'EOF'
{"schemaVersion":1,"kind":"coyote-implementation-observations","phase":"validate","vivadoVersion":"2025.1","vivadoFullVersion":"Vivado v2025.1 Build fixture","analysisKind":"routed","timing":{"setupWnsNs":-0.25,"setupTnsNs":-3.0,"holdWnsNs":0.1,"holdTnsNs":0},"qor":{"rqaScore":null},"routing":{"unroutedNets":1,"partiallyRoutedNets":0,"conflictedNets":0,"hasRoutingErrors":1},"drc":{"errors":1,"criticalWarnings":0,"warnings":2},"reports":{"utilization":"validate-utilization.rpt","timingSummary":"validate-timing.rpt","qorAssessment":"","routeStatus":"validate-route.rpt"}}
EOF
cat > "$work/rejected.json" <<EOF
{"schemaVersion":2,"phase":"validate","unit":"config_0","context":$context,"predecessorPath":"$work/route","outcomePath":"reports/validation.json","telemetry":{"path":"metadata/telemetry.json","executionPath":"metadata/execution.json","physicalPath":"reports/physical.json"},"artifacts":[{"role":"validated-checkpoint","path":"checkpoints/rejected.dcp"},{"role":"validation-result","path":"reports/validation.json"},{"role":"execution-evidence","path":"metadata/execution.json"},{"role":"raw-resource-measurement","path":"metadata/gnu-time.txt"},{"role":"command-stdout","path":"logs/command.stdout.log"},{"role":"command-stderr","path":"logs/command.stderr.log"},{"role":"physical-observations","path":"reports/physical.json"},{"role":"validate-utilization-report","path":"reports/validate-utilization.rpt"},{"role":"validate-timing-summary-report","path":"reports/validate-timing.rpt"},{"role":"validate-route-status-report","path":"reports/validate-route.rpt"},{"role":"bitstream-drc-report","path":"reports/validate-drc.rpt"},{"role":"normalized-telemetry","path":"metadata/telemetry.json"}]}
EOF
python3 "$tool" write "$work/rejected.json" "$work/rejected" "$work/rejected"
jq -e '.outcome == "rejected" and .metrics.physical.drc.errors.value == 1' \
  "$work/rejected/metadata/telemetry.json" >/dev/null
mkdir -p "$work/rejected-image/bitstreams"
printf 'image\n' > "$work/rejected-image/bitstreams/image.pdi"
cat > "$work/rejected-image.json" <<EOF
{"phase":"image","unit":"config_0","context":$context,"predecessorPath":"$work/rejected","artifacts":[{"role":"image","path":"bitstreams/image.pdi"}]}
EOF
expect_failure python3 "$tool" write "$work/rejected-image.json" "$work/rejected-image" "$work/rejected-image"

mkdir -p "$work/image/bitstreams"
printf 'image\n' > "$work/image/bitstreams/image.pdi"
cat > "$work/image.json" <<EOF
{"phase":"image","unit":"config_0","context":$context,"predecessorPath":"$work/validate","outcome":"accepted","artifacts":[{"role":"image","path":"bitstreams/image.pdi"}]}
EOF
python3 "$tool" write "$work/image.json" "$work/image" "$work/image"
python3 "$tool" validate "$work/image" --phase image --context "$context_id"

mkdir -p "$work/image-telemetry/bitstreams" "$work/image-telemetry/metadata" "$work/image-telemetry/logs"
printf 'image telemetry\n' > "$work/image-telemetry/bitstreams/image.pdi"
printf 'image stdout\n' > "$work/image-telemetry/logs/command.stdout.log"
printf 'image stderr\n' > "$work/image-telemetry/logs/command.stderr.log"
cat > "$work/image-telemetry/metadata/gnu-time.txt" <<'EOF'
wallSeconds=1.00
userCpuSeconds=0.50
systemCpuSeconds=0.25
maxRssKiB=512
exitCode=0
EOF
cat > "$work/image-telemetry/metadata/primary-tool.json" <<'EOF'
{"schemaVersion":1,"kind":"coyote-primary-tool-invocation","tool":"vivado","exitCode":1,"completionMarkerObserved":true,"anomaly":"post-completion-nonzero-exit"}
EOF
cat > "$work/image-telemetry/metadata/execution.json" <<'EOF'
{"schemaVersion":1,"kind":"coyote-stage-execution","measurementScope":"build-commands","status":"completed","exitCode":0,"wallSeconds":"1.00","userCpuSeconds":"0.50","systemCpuSeconds":"0.25","maxRssKiB":512,"requestedCores":8,"scratchBytesAfterCommand":2048,"primaryTool":{"schemaVersion":1,"kind":"coyote-primary-tool-invocation","tool":"vivado","exitCode":1,"completionMarkerObserved":true,"anomaly":"post-completion-nonzero-exit"}}
EOF
cat > "$work/image-telemetry.json" <<EOF
{"schemaVersion":2,"phase":"image","unit":"config_0","context":$context,"predecessorPath":"$work/validate","outcome":"accepted","telemetry":{"path":"metadata/telemetry.json","executionPath":"metadata/execution.json","physicalPath":null},"artifacts":[{"role":"image","path":"bitstreams/image.pdi"},{"role":"primary-tool-invocation","path":"metadata/primary-tool.json"},{"role":"execution-evidence","path":"metadata/execution.json"},{"role":"raw-resource-measurement","path":"metadata/gnu-time.txt"},{"role":"command-stdout","path":"logs/command.stdout.log"},{"role":"command-stderr","path":"logs/command.stderr.log"},{"role":"normalized-telemetry","path":"metadata/telemetry.json"}]}
EOF
python3 "$tool" write "$work/image-telemetry.json" "$work/image-telemetry" "$work/image-telemetry"
jq -e '.execution.primaryTool.exitCode == 1 and .execution.primaryTool.anomaly == "post-completion-nonzero-exit"' \
  "$work/image-telemetry/metadata/telemetry.json" >/dev/null

mkdir -p "$work/wrong-unit/bitstreams"
printf 'image\n' > "$work/wrong-unit/bitstreams/image.pdi"
cat > "$work/wrong-unit.json" <<EOF
{"phase":"image","unit":"other_unit","context":$context,"predecessorPath":"$work/validate","artifacts":[{"role":"image","path":"bitstreams/image.pdi"}]}
EOF
expect_failure python3 "$tool" write "$work/wrong-unit.json" "$work/wrong-unit" "$work/wrong-unit"

mkdir -p "$work/escape/checkpoints"
printf 'outside\n' > "$work/outside.dcp"
ln -s "$work/outside.dcp" "$work/escape/checkpoints/escape.dcp"
make_spec inputs '' escape.dcp > "$work/escape.json"
expect_failure python3 "$tool" write "$work/escape.json" "$work/escape" "$work/escape"

expect_failure python3 "$tool" import "$work/validate" "$work/missing-role" absent-role
printf 'implementation stage manifest contract: PASS\n'
