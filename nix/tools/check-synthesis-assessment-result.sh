#!/usr/bin/env bash
set -euo pipefail

validate_only=false
if [[ ${1:-} == --validate-only ]]; then
  validate_only=true
  shift
fi

if [[ $# -ne 1 ]]; then
  echo "usage: check-synthesis-assessment-result [--validate-only] ASSESSMENT.json" >&2
  exit 2
fi

assessment=$1
if [[ ! -f $assessment ]]; then
  echo "ERROR: synthesis assessment does not exist: $assessment" >&2
  exit 2
fi

if ! jq -e '
  .schemaVersion == 1
  and .kind == "coyote-synthesis-assessment"
  and .rawKind == "coyote-synthesis-analysis"
  and .predictiveOnly == true
  and (.classification == "PASS" or .classification == "MARGINAL" or .classification == "FAIL")
  and (.policy.rejectSetupWnsBelow | type == "number")
  and (.policy.passSetupWnsAtLeast | type == "number")
  and .policy.passSetupWnsAtLeast >= .policy.rejectSetupWnsBelow
  and (
    .policy.maximumLogicLevels == null
    or (.policy.maximumLogicLevels | type == "number" and . >= 1)
  )
  and (.reasons | type == "array" and length > 0)
' "$assessment" >/dev/null; then
  echo "ERROR: invalid synthesis-assessment contract: $assessment" >&2
  exit 2
fi

classification=$(jq -r .classification "$assessment")
if [[ $validate_only == true ]]; then
  printf 'SYNTHESIS_ASSESSMENT_VALID classification=%s assessment=%s\n' \
    "$classification" "$assessment"
  exit 0
fi

case "$classification" in
  PASS | MARGINAL)
    printf 'SYNTHESIS_ASSESSMENT_GATE_ACCEPT classification=%s assessment=%s\n' \
      "$classification" "$assessment"
    ;;
  FAIL)
    jq -c '{classification, reasons, timing, policy}' "$assessment" >&2
    printf 'ERROR: synthesized-shell assessment rejected this candidate; inspect %s\n' \
      "${COYOTE_SYNTHESIS_ANALYSIS_PATH:-$assessment}" >&2
    exit 42
    ;;
esac
