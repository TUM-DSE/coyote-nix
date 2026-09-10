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
if {$argc ni {7 8}} {
    puts stderr "usage: runner.tcl TOOL BASE REPORT BOARD PART BUILD_APP BUILD_SHELL ?SYNTHESIZE_BLOCK_DESIGNS?"
    exit 2
}
set tool [lindex $argv 0]
set argv [lrange $argv 1 end]
set argc [llength $argv]
set opened_project ""
set ip_sources_visible 0
set ip_products_ready 0

proc open_project {path} {
    set ::opened_project $path
    set ::ip_sources_visible {}
    set ::ip_products_ready 0
    set ::parent_products_ready 0
    set ::parent_runs_complete {}
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
        IP_FILE {
            return "$object.xci"
        }
        STATUS {
            if {[info exists ::env(TEST_PARENT_RUN_FAILURE)]} { return "synth_design ERROR" }
            if {$object ni $::parent_runs_complete} { error "Parent run not waited on" }
            return "synth_design Complete!"
        }
        default {
            error "unexpected property: $property"
        }
    }
}
proc get_ips {args} {
    if {$args ne {-quiet -exclude_bd_ips}} {
        error "Elaboration must not treat BD child IPs as standalone IPs"
    }
    return {fixture_ip_0 fixture_ip_1}
}
proc get_files {args} {
    if {[lindex $args end] eq {FILE_TYPE == "Block Designs"}} {
        if {[info exists ::env(TEST_BLOCK_DESIGNS)]} { return {parent0.bd parent1.bd} }
        return {}
    }
    set file [lindex $args end]
    if {$file ni {fixture_ip_0.xci fixture_ip_1.xci}} { error "Unknown IP file $file" }
    if {[info exists ::env(TEST_MISSING_IP_FILE)]} { return {} }
    return $file
}
proc set_property {property value objects} {
    if {$property ne "GENERATE_SYNTH_CHECKPOINT" || $value ne "false" ||
        $objects ni {fixture_ip_0.xci fixture_ip_1.xci}} {
        error "Checkpoint policy must apply to standalone IP files: $property $value $objects"
    }
    lappend ::ip_sources_visible $objects
}
proc create_ip_run {bd} {
    if {!$::parent_products_ready} { error "Parent products not generated" }
    if {[info exists ::env(TEST_MISSING_PARENT_RUN)]} { return {} }
    return "${bd}_synth"
}
proc launch_runs {args} {
    if {![info exists ::env(TEST_BLOCK_DESIGNS)]} { error "Unexpected OOC synthesis" }
}
proc wait_on_run {run} { lappend ::parent_runs_complete $run }
proc get_runs {args} {
    if {[info exists ::env(TEST_MISSING_RUN_OBJECT)]} { return {} }
    return [lindex $args end]
}
proc generate_target {target objects} {
    if {$target eq "synthesis" && $objects eq {parent0.bd parent1.bd}} {
        if {[info exists ::env(TEST_PARENT_GENERATION_FAILURE)]} { error "Parent generation failed" }
        set ::parent_products_ready 1
        return
    }
    if {$target ne "synthesis" || $objects ne {fixture_ip_0 fixture_ip_1}} {
        error "unexpected generate_target request: $target $objects"
    }
    if {[lsort $::ip_sources_visible] ne {fixture_ip_0.xci fixture_ip_1.xci}} {
        error "synthesis IP output products generated before top-level source visibility"
    }
    if {[info exists ::env(TEST_IP_GENERATION_FAILURE)]} {
        error "deliberate IP output-product failure"
    }
    set ::ip_products_ready 1
}
proc update_compile_order {args} {
    if {$args ne {-fileset sources_1}} {
        error "unexpected update_compile_order arguments: $args"
    }
    if {[llength $::ip_sources_visible] != 2 || !$::ip_products_ready} {
        error "compile order updated before synthesis IP sources were visible and generated"
    }
    if {[info exists ::env(TEST_BLOCK_DESIGNS)] && [llength $::parent_runs_complete] != 2} {
        error "Parent block designs were not synthesized"
    }
}
proc synth_design {args} {
    foreach required {-rtl -name -top -part} {
        if {[lsearch -exact $args $required] < 0} {
            error "synth_design lacks $required: $args"
        }
    }
    if {[info exists ::env(TEST_MISSING_USER_RTL)]} {
        error "module 'req_parser' not found"
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

mkdir -p "$work/ip-generation-failure"
if run_tool "$work/ip-generation-failure" "$work/base.tcl" 1 0 \
  TEST_IP_GENERATION_FAILURE=1 >/dev/null 2>&1; then
  echo "ERROR: elaboration accepted failed synthesis IP output-product generation" >&2
  exit 1
fi
test ! -e "$work/ip-generation-failure/complete"
test ! -e "$work/ip-generation-failure/units.tsv"

mkdir -p "$work/missing-user-rtl"
if run_tool "$work/missing-user-rtl" "$work/base.tcl" 1 0 \
  TEST_MISSING_USER_RTL=1 >/dev/null 2>&1; then
  echo "ERROR: elaboration accepted omitted user RTL (req_parser)" >&2
  exit 1
fi
test ! -e "$work/missing-user-rtl/complete"
test ! -e "$work/missing-user-rtl/units.tsv"

# V80 permits parent-BD OOC synthesis, but the application itself stays RTL-only.
sed -e 's/set cfg(fdev) u280/set cfg(fdev) v80/' \
  -e 's/xcu280-fsvh2892-2L-e/xcvc1902-vsva2197-2MP-e-S/' \
  "$work/base.tcl" > "$work/v80-base.tcl"
run_v80() {
  env TEST_BLOCK_DESIGNS=1 "$@" tclsh "$work/runner.tcl" "$tool" \
    "$work/v80-base.tcl" "$work/v80-report" v80 xcvc1902-vsva2197-2MP-e-S 1 0 1
}
run_v80
test -f "$work/v80-report/complete"
for failure in TEST_PARENT_GENERATION_FAILURE TEST_PARENT_RUN_FAILURE \
  TEST_MISSING_PARENT_RUN TEST_MISSING_RUN_OBJECT TEST_MISSING_IP_FILE; do
  # Start with prior success to prove failure removes stale completion evidence.
  run_v80 >/dev/null
  if run_v80 "$failure=1" >/dev/null 2>&1; then
    echo "ERROR: mixed-BD elaboration accepted $failure" >&2
    exit 1
  fi
  test ! -e "$work/v80-report/complete"
  test ! -e "$work/v80-report/units.tsv"
done
if run_tool "$work/unapproved-bd" "$work/base.tcl" 1 0 \
  TEST_BLOCK_DESIGNS=1 >/dev/null 2>&1; then
  echo 'ERROR: default RTL-only elaboration unexpectedly synthesized parent BDs' >&2
  exit 1
fi

echo "COYOTE_APP_ELABORATION_CONTRACT_PASS"
