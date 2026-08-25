#!/usr/bin/env bash
set -euo pipefail

tool=${1:?implementation-stage tool required}
work=${TMPDIR:-/tmp}/implementation-stage-contract
rm -rf "$work"
mkdir -p "$work"

expect_failure() {
  if "$@"; then
    echo "unexpected success: $*" >&2
    exit 1
  fi
}

context_without_id='{"board":"v80","architecture":"versal","part":"xcv80","flow":"app","sourceId":"source-fixture","constraintsId":"constraints-fixture","toolId":"vivado-2025.1"}'
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

mkdir -p "$work/rejected/checkpoints" "$work/rejected/reports"
printf 'rejected checkpoint\n' > "$work/rejected/checkpoints/rejected.dcp"
printf '{"outcome":"rejected","reasons":["fixture"]}\n' > "$work/rejected/reports/validation.json"
cat > "$work/rejected.json" <<EOF
{"phase":"validate","unit":"config_0","context":$context,"predecessorPath":"$work/route","outcomePath":"reports/validation.json","artifacts":[{"role":"validated-checkpoint","path":"checkpoints/rejected.dcp"},{"role":"validation-result","path":"reports/validation.json"}]}
EOF
python3 "$tool" write "$work/rejected.json" "$work/rejected" "$work/rejected"
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
