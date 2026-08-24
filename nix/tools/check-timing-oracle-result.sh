#!/usr/bin/env bash
set -euo pipefail

validate_only=false
if [[ ${1:-} == --validate-only ]]; then
  validate_only=true
  shift
fi

if [[ $# -ne 1 ]]; then
  echo "usage: check-timing-oracle-result [--validate-only] SUMMARY.json" >&2
  exit 2
fi

summary=$1
if [[ ! -f $summary ]]; then
  echo "ERROR: timing-oracle summary does not exist: $summary" >&2
  exit 2
fi

if ! jq -e '
  .schemaVersion == 1
  and .kind == "coyote-timing-oracle"
  and .predictiveOnly == true
  and (.classification == "PASS" or .classification == "MARGINAL" or .classification == "FAIL")
  and (.postOpt.rqa | type == "number" and . >= 1 and . <= 5)
  and (
    .postPlace == null
    or (
      (.postPlace.rqa | type == "number" and . >= 1 and . <= 5)
      and (.postPlace.setupWnsNs == null or (.postPlace.setupWnsNs | type == "number"))
      and (.postPlace.setupTnsNs == null or (.postPlace.setupTnsNs | type == "number"))
      and (.postPlace.holdWnsNs == null or (.postPlace.holdWnsNs | type == "number"))
    )
  )
  and (.reasons | type == "array" and length > 0)
' "$summary" >/dev/null; then
  echo "ERROR: invalid timing-oracle summary contract: $summary" >&2
  exit 2
fi

classification=$(jq -r '.classification' "$summary")
if [[ $validate_only == true ]]; then
  printf 'TIMING_ORACLE_RESULT_VALID classification=%s summary=%s\n' "$classification" "$summary"
  exit 0
fi

case "$classification" in
  PASS | MARGINAL)
    printf 'TIMING_ORACLE_GATE_ACCEPT classification=%s summary=%s\n' "$classification" "$summary"
    ;;
  FAIL)
    jq -c '{classification, reasons, postOpt, postPlace}' "$summary" >&2
    printf 'ERROR: predictive timing oracle rejected this candidate; inspect %s\n' \
      "${COYOTE_TIMING_ORACLE_PATH:-$summary}" >&2
    exit 42
    ;;
esac
