#!/usr/bin/env bash
set -euo pipefail

checker=${1:?usage: timing-oracle-result.sh CHECKER}
work=${TMPDIR:?}/timing-oracle-result-test
mkdir -p "$work"

write_summary() {
  local output=$1
  local classification=$2
  local post_place=$3
  jq -n \
    --arg classification "$classification" \
    --argjson postPlace "$post_place" \
    '{
      schemaVersion: 1,
      kind: "coyote-timing-oracle",
      predictiveOnly: true,
      postOpt: {rqa: 3},
      postPlace: $postPlace,
      classification: $classification,
      reasons: ["fixture reason"]
    }' >"$output"
}

write_summary "$work/pass.json" PASS \
  '{"rqa":4,"setupWnsNs":-0.2,"setupTnsNs":-1.0,"holdWnsNs":0.1,"criticalPath":{"startpoint":"src/Q","endpoint":"dst/D","pathGroup":"clk","logicLevels":4}}'
write_summary "$work/marginal.json" MARGINAL \
  '{"rqa":3,"setupWnsNs":-0.8,"setupTnsNs":-20.0,"holdWnsNs":0.0,"criticalPath":{"startpoint":"src/Q","endpoint":"dst/D","pathGroup":"clk","logicLevels":7}}'
write_summary "$work/fail.json" FAIL null

bash "$checker" --validate-only "$work/fail.json" \
  | grep -F 'TIMING_ORACLE_RESULT_VALID classification=FAIL' >/dev/null
bash "$checker" "$work/pass.json" | grep -F 'TIMING_ORACLE_GATE_ACCEPT classification=PASS' >/dev/null
bash "$checker" "$work/marginal.json" | grep -F 'TIMING_ORACLE_GATE_ACCEPT classification=MARGINAL' >/dev/null

set +e
COYOTE_TIMING_ORACLE_PATH=/nix/store/oracle-fixture \
  bash "$checker" "$work/fail.json" >"$work/fail.stdout" 2>"$work/fail.stderr"
status=$?
set -e
test "$status" -eq 42
grep -F 'predictive timing oracle rejected this candidate' "$work/fail.stderr" >/dev/null
grep -F '/nix/store/oracle-fixture' "$work/fail.stderr" >/dev/null

write_summary "$work/inconsistent-pass.json" PASS null
set +e
bash "$checker" "$work/inconsistent-pass.json" >/dev/null 2>"$work/inconsistent-pass.stderr"
status=$?
set -e
test "$status" -eq 2
grep -F 'invalid timing-oracle summary contract' "$work/inconsistent-pass.stderr" >/dev/null

jq '.predictiveOnly = false' "$work/pass.json" >"$work/invalid.json"
set +e
bash "$checker" "$work/invalid.json" >/dev/null 2>"$work/invalid.stderr"
status=$?
set -e
test "$status" -eq 2
grep -F 'invalid timing-oracle summary contract' "$work/invalid.stderr" >/dev/null
