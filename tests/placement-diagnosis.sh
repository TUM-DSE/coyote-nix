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

# A place stage as Coyote's physical_stage writes it for config 0.
make_stage() {
  candidate=$1
  rqa=$2
  slack=$3
  logic=$4
  net=$5
  levels=$6
  congestion=$7
  reports="$work/$candidate/reports/config_0"
  mkdir -p "$reports"
  cat > "$reports/shell_place_diagnosis_c0.json" <<JSON
{"schemaVersion":1,"kind":"coyote-placement-diagnosis-evidence","phase":"place","vivadoVersion":"2025.1","vivadoFullVersion":"Vivado v2025.1 Build fixture","setupPathCount":100,"worstSetupPath":{"source":"source/$candidate","destination":"destination/$candidate","pathGroup":"clk","slackNs":$slack,"requirementNs":4.0,"dataPathDelayNs":3.0,"logicDelayNs":$logic,"netDelayNs":$net,"logicLevels":$levels,"skewNs":0.1},"reports":{"congestion":"shell_place_congestion_c0.rpt","complexity":"shell_place_complexity_c0.rpt","logicLevels":"shell_place_logic_levels_c0.rpt","highFanout":"shell_place_high_fanout_c0.rpt"}}
JSON
  printf 'Overall Congestion Level : %s\n' "$congestion" > "$reports/shell_place_congestion_c0.rpt"
  printf 'complexity evidence\n' > "$reports/shell_place_complexity_c0.rpt"
  printf 'logic-level evidence\n' > "$reports/shell_place_logic_levels_c0.rpt"
  printf 'high-fanout evidence\n' > "$reports/shell_place_high_fanout_c0.rpt"
  printf '{"qor":{"rqaScore":"%s"}}\n' "$rqa" > "$reports/shell_place_physical_c0.json"
  printf '{"candidateId":"%s","place":"%s","physOpt":"Explore"}\n' "$candidate" "$candidate" \
    > "$work/$candidate-strategy.json"
}

normalize() {
  python3 "$tool" normalize "$work/$1" reports/config_0 _c0 "$work/$1-strategy.json" "$2" \
    --candidate-id "$1"
}

make_stage balanced 4 -0.100 1.0 2.0 12 2
make_stage spread 3 -0.050 0.8 2.2 8 1
normalize balanced "$work/balanced-diagnosis.json"
normalize spread "$work/spread-diagnosis.json"
jq -e '
  .api == "coyote-nix.placement-diagnosis/v1"
  and .subject.candidateId == "balanced"
  and .metrics.rqaScore.value == 4
  and .metrics.congestionLevel.value == 2
  and .metrics.worstSetupPath.slackFs.value == -100000
  and .metrics.worstSetupPath.logicDelayFraction.value == 333333
  and (.diagnosisId | test("^[0-9a-f]{64}$"))
' "$work/balanced-diagnosis.json" >/dev/null

cat > "$work/policy.json" <<'JSON'
{"schemaVersion":1,"api":"coyote-nix.placement-recommendation-policy/v1","maxRouteCandidates":2,"weights":{"rqa":1000000,"setupSlackPerPs":1,"logicLevelPenalty":100,"congestionPenalty":1000}}
JSON
python3 "$tool" recommend "$work/policy.json" "$work/recommendation.json" \
  "$work/balanced-diagnosis.json" "$work/spread-diagnosis.json"
jq -e '
  .api == "coyote-nix.placement-recommendation/v1"
  and .advisoryOnly == true
  and .recommendedRouteCandidates == ["balanced", "spread"]
  and .ranking[0].candidateId == "balanced"
  and (.recommendationId | test("^[0-9a-f]{64}$"))
' "$work/recommendation.json" >/dev/null

# A missing report, a candidate that does not match its strategy, duplicate
# candidates and an unbounded policy are rejected.
cp -a "$work/balanced" "$work/incomplete"
cp "$work/balanced-strategy.json" "$work/incomplete-strategy.json"
rm "$work/incomplete/reports/config_0/shell_place_congestion_c0.rpt"
expect_failure normalize incomplete "$work/incomplete.json"
expect_failure python3 "$tool" normalize "$work/balanced" reports/config_0 _c0 \
  "$work/spread-strategy.json" "$work/mismatch.json" --candidate-id balanced
expect_failure python3 "$tool" recommend "$work/policy.json" "$work/duplicate.json" \
  "$work/balanced-diagnosis.json" "$work/balanced-diagnosis.json"
sed 's/"maxRouteCandidates":2/"maxRouteCandidates":3/' "$work/policy.json" > "$work/unbounded-policy.json"
expect_failure python3 "$tool" recommend "$work/unbounded-policy.json" "$work/unbounded.json" \
  "$work/balanced-diagnosis.json" "$work/spread-diagnosis.json"

printf 'placement-diagnosis: PASS\n'
