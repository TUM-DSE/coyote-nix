#!/usr/bin/env bash
set -euo pipefail

runner=${1:?stage runner required}
work=${TMPDIR:-/tmp}/stage-execution-evidence
rm -rf "$work"
mkdir -p "$work/src"
cat > "$work/src/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.10)
project(stage_execution_fixture NONE)
EOF
: > "$work/pre.sh"
: > "$work/expected.txt"

run_case() {
  local name=$1
  local command=$2
  local expected_status=$3
  local build="$work/$name"
  printf '%s\n' "$command" > "$work/$name-commands.sh"
  if bash "$runner" \
      "$work/src" "$build" "$work/pre.sh" "$work/$name-commands.sh" \
      "$work/expected.txt" -DCOMP_CORES=99; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne "$expected_status" ]; then
    echo "unexpected runner status for $name: $status" >&2
    exit 1
  fi
  test -f "$build/metadata/execution.json"
  test -f "$build/logs/command.stdout.log"
  test -f "$build/logs/command.stderr.log"
}

run_case success "grep -Fx 'COMP_CORES:UNINITIALIZED=3' CMakeCache.txt; printf 'fixture stdout\\n'; printf 'fixture stderr\\n' >&2" 0
jq -e '
  .schemaVersion == 1
  and .kind == "coyote-stage-execution"
  and .measurementScope == "build-commands"
  and .status == "completed"
  and .exitCode == 0
  and .requestedCores == 3
  and (.wallSeconds | type == "string")
  and (.userCpuSeconds | type == "string")
  and (.systemCpuSeconds | type == "string")
  and (.maxRssKiB | type == "number")
  and (.scratchBytesAfterCommand | type == "number")
' "$work/success/metadata/execution.json" >/dev/null
grep -Fx 'fixture stdout' "$work/success/logs/command.stdout.log" >/dev/null
grep -Fx 'fixture stderr' "$work/success/logs/command.stderr.log" >/dev/null

run_case failure "printf 'before failure\\n'; exit 7" 7
jq -e '.status == "failed" and .exitCode == 7' \
  "$work/failure/metadata/execution.json" >/dev/null
grep -Fx 'before failure' "$work/failure/logs/command.stdout.log" >/dev/null

run_case intermediate-failure "false; printf 'must not run\\n'" 1
if grep -F 'must not run' "$work/intermediate-failure/logs/command.stdout.log" >/dev/null; then
  echo 'command continued after an intermediate failure' >&2
  exit 1
fi
run_case pipeline-failure "false | cat; printf 'must not run\\n'" 1
if grep -F 'must not run' "$work/pipeline-failure/logs/command.stdout.log" >/dev/null; then
  echo 'command continued after a pipeline failure' >&2
  exit 1
fi

printf 'stage execution evidence contract: PASS\n'
