#!/usr/bin/env bash
set -euo pipefail

assessor=${1:?usage: synthesis-assessment-result.sh ASSESSOR CHECKER}
checker=${2:?usage: synthesis-assessment-result.sh ASSESSOR CHECKER}
work=${TMPDIR:?}/synthesis-assessment-result-test
mkdir -p "$work"

write_raw() {
  path=$1
  valid=$2
  setup_wns=$3
  logic_levels=$4
  jq -n \
    --argjson valid "$valid" \
    --argjson setupWnsNs "$setup_wns" \
    --argjson logicLevels "$logic_levels" '
    {
      schemaVersion: 1,
      kind: "coyote-synthesis-analysis",
      predictiveOnly: true,
      assessmentScope: "resident-shell-synthesis",
      architecture: "versal",
      part: "xcv80-test",
      vivadoVersion: "2025.1",
      implementation: {
        linked: false,
        optimized: false,
        placed: false,
        routed: false
      },
      reportLimits: { maxPaths: 100, maxFanoutNets: 100 },
      timing: {
        setupWnsNs: $setupWnsNs,
        setupTnsNs: -12.5,
        holdWnsNs: 0.125,
        criticalPath: {
          startpoint: "source_reg/C",
          endpoint: "target_reg/D",
          pathGroup: "aclk",
          logicLevels: $logicLevels
        }
      },
      valid: $valid,
      reasons: ["fixture"]
    }
  ' > "$path"
}

write_raw "$work/pass-raw.json" true 0.75 8
write_raw "$work/marginal-raw.json" true 0.25 8
write_raw "$work/fail-raw.json" true -0.25 8
write_raw "$work/logic-fail-raw.json" true 0.75 18
write_raw "$work/invalid-raw.json" false null null
jq '.assessmentScope = "module-out-of-context"' \
  "$work/pass-raw.json" > "$work/module-raw.json"

bash "$assessor" "$work/pass-raw.json" "$work/pass.json" 0.0 0.5 null
bash "$assessor" "$work/module-raw.json" "$work/module.json" 0.0 0.5 null
bash "$assessor" "$work/marginal-raw.json" "$work/marginal.json" 0.0 0.5 null
bash "$assessor" "$work/fail-raw.json" "$work/fail.json" 0.0 0.5 null
bash "$assessor" "$work/logic-fail-raw.json" "$work/logic-fail.json" 0.0 0.5 12
bash "$assessor" "$work/invalid-raw.json" "$work/invalid.json" 0.0 0.5 null

test "$(jq -r .classification "$work/pass.json")" = PASS
test "$(jq -r .classification "$work/module.json")" = PASS
test "$(jq -r .assessmentScope "$work/module.json")" = module-out-of-context
test "$(jq -r .classification "$work/marginal.json")" = MARGINAL
test "$(jq -r .classification "$work/fail.json")" = FAIL
test "$(jq -r .classification "$work/logic-fail.json")" = FAIL
test "$(jq -r .classification "$work/invalid.json")" = FAIL

bash "$checker" --validate-only "$work/pass.json"
bash "$checker" "$work/pass.json"
bash "$checker" "$work/marginal.json"
if COYOTE_SYNTHESIS_ANALYSIS_PATH=/nix/store/example-synthesis-analysis \
  bash "$checker" "$work/fail.json" >"$work/fail.stdout" 2>"$work/fail.stderr"; then
  echo "FAIL assessment unexpectedly passed its rejecting gate" >&2
  exit 1
fi
grep -F '/nix/store/example-synthesis-analysis' "$work/fail.stderr" >/dev/null

jq '.kind = "invalid"' "$work/pass.json" > "$work/malformed.json"
if bash "$checker" --validate-only "$work/malformed.json" \
  >"$work/malformed.stdout" 2>"$work/malformed.stderr"; then
  echo "malformed synthesis assessment unexpectedly validated" >&2
  exit 1
fi
grep -F 'invalid synthesis-assessment contract' "$work/malformed.stderr" >/dev/null

if bash "$assessor" "$work/pass-raw.json" "$work/bad-policy.json" 1.0 0.5 null \
  >"$work/policy.stdout" 2>"$work/policy.stderr"; then
  echo "invalid synthesis policy unexpectedly passed" >&2
  exit 1
fi
grep -F 'pass WNS must be at least' "$work/policy.stderr" >/dev/null

printf 'SYNTHESIS_ASSESSMENT_RESULT_PASS\n'
