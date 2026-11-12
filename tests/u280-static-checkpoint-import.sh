#!/usr/bin/env bash
# Import of an earlier build's routed U280 shell checkpoint as a static layer.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <import-tool>" >&2
  exit 2
fi
tool=$1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

stage="$work/stage"
mkdir -p "$stage/checkpoints" "$stage/reports"
printf 'routed shell checkpoint\n' > "$stage/checkpoints/shell_routed.dcp"
cat > "$stage/reports/shell_route_status.rpt" <<'EOF'
Design Route Status
 # of routable nets............................. :          12 :
 # of nets with fixed routing................... :           7 :
 # of fully routed nets......................... :          12 :
 # of nets with routing errors.................. :           0 :
EOF
printf '{"outcome":"accepted","reasons":[],"schemaVersion":1}\n' > "$stage/reports/validation.json"

checkpoint_sha256=$(sha256sum "$stage/checkpoints/shell_routed.dcp" | cut -d ' ' -f 1)
import() {
  python3 "$tool" "$1" "$2" --checkpoint-sha256 "$3" --fixed-route-nets "$4" --tool-version 2023.2
}
rejected() {
  if import "$@" >/dev/null 2>&1; then
    echo "import accepted: $*" >&2
    exit 1
  fi
}

import "$stage" "$work/imported" "$checkpoint_sha256" 7
cmp "$stage/checkpoints/shell_routed.dcp" "$work/imported/checkpoints/static_routed_locked_u280.dcp"
test -f "$work/imported/reports/shell_route_status.rpt"
jq -e '
  .api == "coyote-nix.u280-static-checkpoint/v1"
  and .compatibility.board == "u280"
  and .protectedStatic.lockLevel == "routing"
  and .protectedStatic.fixedRouteNets == 7
  and .applicationLink.protectedStatic == "reject-drift"
' "$work/imported/metadata/static-checkpoint.json" >/dev/null

# A different checkpoint, a changed lock count or incomplete routing.
rejected "$stage" "$work/wrong-hash" "$(printf '0%.0s' {1..64})" 7
rejected "$stage" "$work/wrong-lock" "$checkpoint_sha256" 8
incomplete="$work/incomplete"
cp -a "$stage" "$incomplete"
sed -i 's/fully routed nets......................... :          12/fully routed nets......................... :          11/' \
  "$incomplete/reports/shell_route_status.rpt"
rejected "$incomplete" "$work/incomplete-out" "$checkpoint_sha256" 7

# A failed validation of the source is reported, not rejected.
failed="$work/failed-validation"
cp -a "$stage" "$failed"
printf '{"outcome":"rejected","reasons":["setup WNS -0.1 ns"],"schemaVersion":1}\n' \
  > "$failed/reports/validation.json"
import "$failed" "$work/failed-out" "$checkpoint_sha256" 7 2> "$work/failed.log"
grep -q 'setup WNS -0.1 ns' "$work/failed.log"

printf 'u280 static checkpoint import: PASS\n'
