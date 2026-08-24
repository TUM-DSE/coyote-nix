#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: assess-synthesis-analysis-result RAW.json OUTPUT.json REJECT_WNS PASS_WNS MAX_LOGIC_LEVELS_OR_NULL" >&2
  exit 2
}

[[ $# -eq 5 ]] || usage
raw=$1
output=$2
reject_wns=$3
pass_wns=$4
max_logic_levels=$5

if [[ ! -f $raw ]]; then
  echo "ERROR: synthesis-analysis summary does not exist: $raw" >&2
  exit 2
fi

number_re='^-?([0-9]+([.][0-9]*)?|[.][0-9]+)$'
if [[ ! $reject_wns =~ $number_re || ! $pass_wns =~ $number_re ]]; then
  echo "ERROR: synthesis-analysis WNS thresholds must be numbers" >&2
  exit 2
fi
if ! awk -v reject="$reject_wns" -v pass="$pass_wns" 'BEGIN { exit !(pass >= reject) }'; then
  echo "ERROR: synthesis-analysis pass WNS must be at least the rejection WNS" >&2
  exit 2
fi
if [[ $max_logic_levels != null ]] &&
  { [[ ! $max_logic_levels =~ ^[0-9]+$ ]] || [[ $max_logic_levels -lt 1 ]]; }; then
  echo "ERROR: maximum logic levels must be null or a positive integer" >&2
  exit 2
fi

if ! jq -e '
  .schemaVersion == 1
  and .kind == "coyote-synthesis-analysis"
  and .predictiveOnly == true
  and .assessmentScope == "resident-shell-synthesis"
  and (.architecture | type == "string" and length > 0)
  and (.part | type == "string" and length > 0)
  and (.vivadoVersion | type == "string" and length > 0)
  and .implementation == {
    linked: false,
    optimized: false,
    placed: false,
    routed: false
  }
  and (.reportLimits.maxPaths | type == "number" and . >= 1)
  and (.reportLimits.maxFanoutNets | type == "number" and . >= 1)
  and (.timing.setupWnsNs == null or (.timing.setupWnsNs | type == "number"))
  and (.timing.setupTnsNs == null or (.timing.setupTnsNs | type == "number"))
  and (.timing.holdWnsNs == null or (.timing.holdWnsNs | type == "number"))
  and (.timing.criticalPath.startpoint | type == "string")
  and (.timing.criticalPath.endpoint | type == "string")
  and (.timing.criticalPath.pathGroup | type == "string")
  and (
    .timing.criticalPath.logicLevels == null
    or (.timing.criticalPath.logicLevels | type == "number" and . >= 0)
  )
  and (.valid | type == "boolean")
  and (.reasons | type == "array" and length > 0)
' "$raw" >/dev/null; then
  echo "ERROR: invalid synthesis-analysis summary contract: $raw" >&2
  exit 2
fi

jq \
  --argjson rejectSetupWnsBelow "$reject_wns" \
  --argjson passSetupWnsAtLeast "$pass_wns" \
  --argjson maximumLogicLevels "$max_logic_levels" '
  def fail_reason($message): { classification: "FAIL", reason: $message };
  def classify:
    if .valid != true then
      fail_reason("synthesized resident-shell timing evidence is incomplete")
    elif .timing.setupWnsNs == null then
      fail_reason("synthesized resident-shell setup WNS is unavailable")
    elif .timing.setupWnsNs < $rejectSetupWnsBelow then
      fail_reason(
        "synthesized setup WNS \(.timing.setupWnsNs) ns is below rejection threshold \($rejectSetupWnsBelow) ns"
      )
    elif $maximumLogicLevels != null and .timing.criticalPath.logicLevels == null then
      fail_reason("critical-path logic levels are unavailable for the configured limit")
    elif $maximumLogicLevels != null and .timing.criticalPath.logicLevels > $maximumLogicLevels then
      fail_reason(
        "critical path has \(.timing.criticalPath.logicLevels) logic levels, above limit \($maximumLogicLevels)"
      )
    elif .timing.setupWnsNs >= $passSetupWnsAtLeast then
      {
        classification: "PASS",
        reason: "synthesized setup WNS meets the configured pass threshold; placement and routing remain unassessed"
      }
    else
      {
        classification: "MARGINAL",
        reason: "synthesized setup WNS requires stronger linked-oracle judgment"
      }
    end;
  . as $raw
  | classify as $assessment
  | $raw + {
      kind: "coyote-synthesis-assessment",
      rawKind: $raw.kind,
      policy: {
        rejectSetupWnsBelow: $rejectSetupWnsBelow,
        passSetupWnsAtLeast: $passSetupWnsAtLeast,
        maximumLogicLevels: $maximumLogicLevels
      },
      classification: $assessment.classification,
      reasons: ($raw.reasons + [$assessment.reason])
    }
' "$raw" > "$output"

classification=$(jq -r .classification "$output")
printf 'SYNTHESIS_ASSESSMENT_COMPLETE classification=%s output=%s\n' "$classification" "$output"
