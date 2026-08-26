#!/usr/bin/env bash
set -euo pipefail

tool=${1:?placement diagnosis tool required}
work=${TMPDIR:-/tmp}/placement-diagnosis-contract
rm -rf "$work"
mkdir -p "$work"

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "unexpected success: $*" >&2
    exit 1
  fi
}

make_stage() {
  candidate=$1
  rqa=$2
  slack=$3
  logic=$4
  net=$5
  levels=$6
  congestion=$7
  stage="$work/$candidate"
  mkdir -p "$stage/metadata" "$stage/reports"
  cat > "$stage/reports/diagnosis.json" <<EOF
{"schemaVersion":1,"kind":"coyote-placement-diagnosis-evidence","phase":"place","vivadoVersion":"2025.1","vivadoFullVersion":"Vivado v2025.1 Build fixture","setupPathCount":100,"worstSetupPath":{"source":"source/$candidate","destination":"destination/$candidate","pathGroup":"clk","slackNs":$slack,"requirementNs":4.0,"dataPathDelayNs":3.0,"logicDelayNs":$logic,"netDelayNs":$net,"logicLevels":$levels,"skewNs":0.1},"reports":{"congestion":"congestion.rpt","complexity":"complexity.rpt","logicLevels":"logic-levels.rpt","highFanout":"high-fanout.rpt"}}
EOF
  printf 'Overall Congestion Level : %s\n' "$congestion" > "$stage/reports/congestion.rpt"
  printf 'complexity evidence\n' > "$stage/reports/complexity.rpt"
  printf 'logic-level evidence\n' > "$stage/reports/logic-levels.rpt"
  printf 'high-fanout evidence\n' > "$stage/reports/high-fanout.rpt"
  cat > "$stage/metadata/telemetry.json" <<EOF
{"schemaVersion":1,"api":"coyote-nix.implementation-telemetry/v1","metrics":{"physical":{"qor":{"rqaScore":{"state":"available","value":$rqa,"unit":"score","sources":[{"kind":"artifact","role":"physical-observations"}]}}}}}
EOF
  python3 - "$stage" "$candidate" <<'PY'
import hashlib, json, pathlib, sys
stage = pathlib.Path(sys.argv[1])
candidate = sys.argv[2]
roles = {
    "place-diagnosis-observations": "reports/diagnosis.json",
    "place-congestion-report": "reports/congestion.rpt",
    "place-complexity-report": "reports/complexity.rpt",
    "place-logic-level-report": "reports/logic-levels.rpt",
    "place-high-fanout-report": "reports/high-fanout.rpt",
    "normalized-telemetry": "metadata/telemetry.json",
}
artifacts = []
for role, relative in roles.items():
    path = stage / relative
    artifacts.append({"role": role, "path": relative, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "size": path.stat().st_size})
manifest = {
    "schemaVersion": 2,
    "api": "coyote-nix.implementation-stage/v2",
    "phase": "place",
    "manifestId": hashlib.sha256((candidate + "-manifest").encode()).hexdigest(),
    "recipeId": hashlib.sha256((candidate + "-recipe").encode()).hexdigest(),
    "context": {"id": "context-fixture", "architecture": "versal", "board": "v80"},
    "strategy": {"candidateId": candidate, "place": candidate, "physOpt": "Explore"},
    "artifacts": artifacts,
}
(stage / "metadata/stage.json").write_text(json.dumps(manifest, sort_keys=True))
PY
}

make_stage balanced 4 -0.100 1.0 2.0 12 2
make_stage spread 3 -0.050 0.8 2.2 8 1
python3 "$tool" normalize "$work/balanced" "$work/balanced-diagnosis.json" --candidate-id balanced
python3 "$tool" normalize "$work/spread" "$work/spread-diagnosis.json" --candidate-id spread
jq -e '
  .api == "coyote-nix.placement-diagnosis/v1"
  and .subject.candidateId == "balanced"
  and .metrics.congestionLevel.value == 2
  and .metrics.worstSetupPath.slackFs.value == -100000
  and .metrics.worstSetupPath.logicDelayFraction.value == 333333
  and (.diagnosisId | test("^[0-9a-f]{64}$"))
' "$work/balanced-diagnosis.json" >/dev/null

cat > "$work/policy.json" <<'EOF'
{"schemaVersion":1,"api":"coyote-nix.placement-recommendation-policy/v1","maxRouteCandidates":2,"weights":{"rqa":1000000,"setupSlackPerPs":1,"logicLevelPenalty":100,"congestionPenalty":1000}}
EOF
python3 "$tool" recommend "$work/policy.json" "$work/recommendation.json" \
  "$work/balanced-diagnosis.json" "$work/spread-diagnosis.json"
jq -e '
  .api == "coyote-nix.placement-recommendation/v1"
  and .advisoryOnly == true
  and .recommendedRouteCandidates == ["balanced", "spread"]
  and .ranking[0].candidateId == "balanced"
  and (.recommendationId | test("^[0-9a-f]{64}$"))
' "$work/recommendation.json" >/dev/null

cp -a "$work/balanced" "$work/tampered"
printf 'tamper\n' >> "$work/tampered/reports/congestion.rpt"
expect_failure python3 "$tool" normalize "$work/tampered" "$work/tampered.json"
expect_failure python3 "$tool" recommend "$work/policy.json" "$work/duplicate.json" \
  "$work/balanced-diagnosis.json" "$work/balanced-diagnosis.json"
sed 's/"maxRouteCandidates":2/"maxRouteCandidates":3/' "$work/policy.json" > "$work/unbounded-policy.json"
expect_failure python3 "$tool" recommend "$work/unbounded-policy.json" "$work/unbounded.json" \
  "$work/balanced-diagnosis.json" "$work/spread-diagnosis.json"

printf 'placement-diagnosis: PASS\n'
