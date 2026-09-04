#!/usr/bin/env bash
set -euo pipefail

runner=${1:?stage runner required}
work=${TMPDIR:-/tmp}/timing-policy-propagation
rm -rf "$work"
mkdir -p "$work/src"

cat > "$work/src/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.10)
project(timing_policy_fixture NONE)

set(EN_TIMING_CHECK 0 CACHE BOOL "Reject negative routed timing")
# Model a consumer's project policy. An explicit package request must still be
# authoritative for the generated implementation stage.
set(EN_TIMING_CHECK 1)
configure_file(base.tcl.in "${CMAKE_BINARY_DIR}/base.tcl")
configure_file(stage.tcl.in "${CMAKE_BINARY_DIR}/stage.tcl" COPYONLY)
EOF

cat > "$work/src/base.tcl.in" <<'EOF'
set cfg(en_timing_check) ${EN_TIMING_CHECK}
set cfg(clock_period_ns) 4.000
EOF

cat > "$work/src/stage.tcl.in" <<'EOF'
source [file join [file dirname [info script]] base.tcl]

file mkdir reports
set timing [open reports/timing-summary.rpt w]
puts $timing "Clock period: $cfg(clock_period_ns) ns"
puts $timing "WNS(ns): -0.159"
puts $timing "Timing constraints are not met."
close $timing

set route [open reports/route-status.rpt w]
puts $route "Design State: Fully Routed"
puts $route "Routing Errors: 0"
close $route

set drc [open reports/bitstream-drc.rpt w]
puts $drc "Errors: 0"
puts $drc "Critical Warnings: 0"
close $drc

set vivado_log [open vivado.log w]
puts $vivado_log "Timing constraints are not met."
close $vivado_log

if {$cfg(en_timing_check) eq 1} {
    puts stderr "CERR: routed fixture has negative max slack: -0.159 ns"
    exit 9
}

file mkdir checkpoints
set checkpoint [open checkpoints/shell_routed.dcp w]
puts $checkpoint "fully routed checkpoint"
close $checkpoint
set completion [open checkpoints/shell_route_complete w]
puts $completion "shell route complete"
close $completion
EOF

read_generated_policy() {
  local base_tcl=$1

  tclsh <<EOF
source {$base_tcl}
puts \$cfg(en_timing_check)
EOF
}

: > "$work/pre.sh"
cat > "$work/expected.txt" <<'EOF'
reports/timing-summary.rpt
reports/route-status.rpt
reports/bitstream-drc.rpt
checkpoints/shell_routed.dcp
checkpoints/shell_route_complete
EOF

cat > "$work/nonstrict-commands.sh" <<'EOF'
test "$COYOTE_NIX_EN_TIMING_CHECK" = 0
test "$COYOTE_NIX_CHECK_TIMING_LOG" = 0
cmake -LA -N . | grep -Fx 'EN_TIMING_CHECK:BOOL=OFF'
tclsh stage.tcl
EOF

bash "$runner" \
  "$work/src" "$work/nonstrict" "$work/pre.sh" \
  "$work/nonstrict-commands.sh" "$work/expected.txt" \
  -DEN_TIMING_CHECK:BOOL=OFF

test "$(read_generated_policy "$work/nonstrict/base.tcl")" = 0
grep -Fx 'Clock period: 4.000 ns' "$work/nonstrict/reports/timing-summary.rpt" >/dev/null
grep -Fx 'WNS(ns): -0.159' "$work/nonstrict/reports/timing-summary.rpt" >/dev/null
grep -Fx 'Timing constraints are not met.' "$work/nonstrict/reports/timing-summary.rpt" >/dev/null
grep -Fx 'Design State: Fully Routed' "$work/nonstrict/reports/route-status.rpt" >/dev/null
grep -Fx 'Routing Errors: 0' "$work/nonstrict/reports/route-status.rpt" >/dev/null
grep -Fx 'Errors: 0' "$work/nonstrict/reports/bitstream-drc.rpt" >/dev/null
grep -Fx 'Critical Warnings: 0' "$work/nonstrict/reports/bitstream-drc.rpt" >/dev/null
jq -e '.status == "completed" and .exitCode == 0' \
  "$work/nonstrict/metadata/execution.json" >/dev/null

cat > "$work/strict-commands.sh" <<'EOF'
test "$COYOTE_NIX_EN_TIMING_CHECK" = 1
test "$COYOTE_NIX_CHECK_TIMING_LOG" = 0
cmake -LA -N . | grep -Fx 'EN_TIMING_CHECK:BOOL=ON'
tclsh stage.tcl
EOF

set +e
bash "$runner" \
  "$work/src" "$work/strict" "$work/pre.sh" \
  "$work/strict-commands.sh" "$work/expected.txt" \
  -DEN_TIMING_CHECK:BOOL=ON
strict_status=$?
set -e
test "$strict_status" -eq 9
test "$(read_generated_policy "$work/strict/base.tcl")" = 1
test ! -e "$work/strict/checkpoints/shell_routed.dcp"
grep -F 'CERR: routed fixture has negative max slack: -0.159 ns' \
  "$work/strict/logs/command.stderr.log" >/dev/null
jq -e '.status == "failed" and .exitCode == 9' \
  "$work/strict/metadata/execution.json" >/dev/null

cat > "$work/project-policy-commands.sh" <<'EOF'
test -z "${COYOTE_NIX_EN_TIMING_CHECK+x}"
tclsh stage.tcl
EOF

set +e
bash "$runner" \
  "$work/src" "$work/project-policy" "$work/pre.sh" \
  "$work/project-policy-commands.sh" "$work/expected.txt"
project_status=$?
set -e
test "$project_status" -eq 9
test "$(read_generated_policy "$work/project-policy/base.tcl")" = 1
jq -e '.status == "failed" and .exitCode == 9' \
  "$work/project-policy/metadata/execution.json" >/dev/null

printf 'timing policy propagation contract: PASS\n'
