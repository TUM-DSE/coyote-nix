#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 COYOTE_APP_ELABORATION_TCL" >&2
  exit 2
fi

tool="$1"
work="${TMPDIR:?}/app-elaboration-fixture"
rm -rf "$work"
mkdir -p "$work/build" "$work/report"

cat > "$work/base.tcl" <<EOF
set project "fixture"
set part "xcu280-fsvh2892-2L-e"
set build_dir "$work/build"
set cfg(build_app) 1
set cfg(build_shell) 0
set cfg(fdev) u280
set cfg(n_config) 2
set cfg(n_reg) 2
EOF

for config in 0 1; do
  for region in 0 1; do
    project_dir="$work/build/fixture_config_$config/user_c${config}_$region"
    mkdir -p "$project_dir"
    : > "$project_dir/fixture.xpr"
  done
done

cat > "$work/runner.tcl" <<'EOF'
if {$argc != 7} {
    puts stderr "usage: runner.tcl TOOL BASE REPORT BOARD PART BUILD_APP BUILD_SHELL"
    exit 2
}
set tool [lindex $argv 0]
set argv [lrange $argv 1 end]
set argc [llength $argv]
set opened_project ""

proc open_project {path} {
    set ::opened_project $path
}
proc current_project {} {
    return fixture_project
}
proc current_fileset {} {
    return sources_1
}
proc get_property {property object} {
    switch -- $property {
        SOURCE_MGMT_MODE {
            if {[info exists ::env(TEST_SOURCE_MODE)]} {
                return $::env(TEST_SOURCE_MODE)
            }
            return All
        }
        TOP {
            return design_user_wrapper_0
        }
        default {
            error "unexpected property: $property"
        }
    }
}
proc update_compile_order {args} {
    if {$args ne {-fileset sources_1}} {
        error "unexpected update_compile_order arguments: $args"
    }
}
proc synth_design {args} {
    foreach required {-rtl -name -top -part} {
        if {[lsearch -exact $args $required] < 0} {
            error "synth_design lacks $required: $args"
        }
    }
    if {[info exists ::env(TEST_SYNTH_FAILURE)]} {
        error "deliberate elaboration failure"
    }
}
proc close_design {} {}
proc close_project {} {
    set ::opened_project ""
}
source $tool
EOF

run_tool() {
  report="$1"
  base="$2"
  build_app="$3"
  build_shell="$4"
  shift 4
  env "$@" tclsh "$work/runner.tcl" "$tool" "$base" "$report" \
    u280 xcu280-fsvh2892-2L-e "$build_app" "$build_shell"
}

run_tool "$work/report" "$work/base.tcl" 1 0
test -f "$work/report/complete"
test "$(cat "$work/report/complete")" = 'coyote-nix.app-elaboration/v1'
test "$(wc -l < "$work/report/units.tsv")" -eq 5
tail -n +2 "$work/report/units.tsv" \
  | awk -F '\t' '
      NF != 5 { exit 1 }
      $3 != "design_user_wrapper_0" { exit 1 }
      $4 != "xcu280-fsvh2892-2L-e" { exit 1 }
      $5 != "All" { exit 1 }
      { seen[$1 ":" $2] = 1 }
      END { exit !(seen["0:0"] && seen["0:1"] && seen["1:0"] && seen["1:1"]) }
    '

sed -e 's/set cfg(build_app) 1/set cfg(build_app) 0/' \
  -e 's/set cfg(build_shell) 0/set cfg(build_shell) 1/' \
  "$work/base.tcl" > "$work/shell-base.tcl"
run_tool "$work/shell-report" "$work/shell-base.tcl" 0 1
test -f "$work/shell-report/complete"
test "$(wc -l < "$work/shell-report/units.tsv")" -eq 5

mkdir -p "$work/wrong-mode"
if run_tool "$work/wrong-mode" "$work/base.tcl" 1 0 \
  TEST_SOURCE_MODE=DisplayOnly >/dev/null 2>&1; then
  echo "ERROR: elaboration accepted non-automatic source management" >&2
  exit 1
fi
test ! -e "$work/wrong-mode/complete"
test ! -e "$work/wrong-mode/units.tsv"

mkdir -p "$work/synth-failure"
if run_tool "$work/synth-failure" "$work/base.tcl" 1 0 \
  TEST_SYNTH_FAILURE=1 >/dev/null 2>&1; then
  echo "ERROR: elaboration accepted a failed top-level synth_design -rtl" >&2
  exit 1
fi
test ! -e "$work/synth-failure/complete"
test ! -e "$work/synth-failure/units.tsv"

if grep -E '(^|[[:space:]])(launch_runs|write_checkpoint|opt_design|place_design|route_design)([[:space:]]|$)' \
  "$tool" >/dev/null; then
  echo "ERROR: RTL elaboration tool contains synthesis or implementation commands" >&2
  exit 1
fi

echo "COYOTE_APP_ELABORATION_CONTRACT_PASS"
