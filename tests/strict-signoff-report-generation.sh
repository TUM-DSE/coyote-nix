#!/usr/bin/env bash
set -euo pipefail

report_tool=${1:?signoff report Tcl required}
signoff_tool=${2:?strict-signoff tool required}
fixtures=${3:?strict-signoff fixture directory required}
work=${TMPDIR:-/tmp}/strict-signoff-report-generation
rm -rf "$work"
mkdir -p "$work"
printf 'checkpoint fixture\n' > "$work/checkpoint.dcp"

python3 - "$work/context.json" <<'PY'
import hashlib, json, sys
context = {
    "board": "v80",
    "architecture": "versal",
    "part": "xcv80-fixture",
    "flow": "build-app",
    "sourceId": "source-fixture",
    "coyoteSourceId": "coyote-source-fixture",
    "constraintsId": "constraints-fixture",
    "toolId": "vivado-fixture",
}
context["id"] = hashlib.sha256(
    json.dumps(context, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
json.dump(context, open(sys.argv[1], "w", encoding="utf-8"), sort_keys=True, separators=(",", ":"))
PY

cat > "$work/fake-vivado.tcl" <<'TCL'
set report_script [lindex $argv 0]
set fixture_dir [lindex $argv 1]
set argv [lrange $argv 2 end]
set argc [llength $argv]

proc report_file {arguments} {
    set index [lsearch -exact $arguments -file]
    if {$index < 0 || $index + 1 >= [llength $arguments]} {
        error "fake report command did not receive -file"
    }
    return [lindex $arguments [expr {$index + 1}]]
}
proc copy_fixture {name arguments} {
    global fixture_dir
    set output [report_file $arguments]
    file mkdir [file dirname $output]
    file copy -force [file join $fixture_dir $name] $output
}
proc open_checkpoint {path} {
    if {![file isfile $path]} { error "missing fake checkpoint: $path" }
}
proc report_methodology {args} { copy_fixture methodology.rpt $args }
proc report_exceptions {args} { copy_fixture timing-exceptions.rpt $args }
proc report_bus_skew {args} { copy_fixture bus-skew.rpt $args }
proc report_clock_interaction {args} { copy_fixture clock-interaction.rpt $args }
proc check_timing {args} { copy_fixture unconstrained-endpoints.rpt $args }
proc get_pins {args} {
    set object_index [lsearch -exact $args -of_objects]
    if {$object_index >= 0} {
        set object [lindex $args [expr {$object_index + 1}]]
        if {$object eq {fixture/disabled_counter_reg[0]}} {
            return [list \
                {fixture/disabled_counter_reg[0]/D} \
                {fixture/disabled_counter_reg[0]/C}]
        }
        return {}
    }
    set query [lindex $args end]
    if {$query eq {fixture/disabled_counter_reg[0]/D}} {
        return [list {fixture/disabled_counter_reg[0]/D}]
    }
    return {}
}
proc get_cells {args} {
    set object_index [lsearch -exact $args -of_objects]
    if {$object_index >= 0 &&
            [lindex $args [expr {$object_index + 1}]] eq
                {fixture/disabled_counter_reg[0]/D}} {
        return [list {fixture/disabled_counter_reg[0]}]
    }
    return {}
}
proc get_clocks {args} { return {} }
proc get_property {args} {
    set property [lindex $args end-1]
    set object [lindex $args end]
    switch -- $property {
        NAME { return $object }
        IS_CLOCK {
            return [expr {$object eq {fixture/disabled_counter_reg[0]/C}}]
        }
        CONSTANT_VALUE {
            if {$object eq {fixture/disabled_counter_reg[0]/C}} { return 0 }
            return ""
        }
    }
    error "unsupported fake property: $property"
}
proc report_drc {args} { copy_fixture drc.rpt $args }
proc report_timing_summary {args} { copy_fixture timing-summary.rpt $args }
proc report_route_status {args} { copy_fixture route-status.rpt $args }
proc close_project {} {}

source $report_script
TCL

for phase in link place route validate; do
  report_dir="$work/$phase/reports"
  mkdir -p "$report_dir"
  cp "$work/checkpoint.dcp" "$work/$phase/checkpoint.dcp"
  route_applicable=0
  if [ "$phase" = route ] || [ "$phase" = validate ]; then
    route_applicable=1
  fi
  tclsh "$work/fake-vivado.tcl" "$report_tool" "$fixtures" \
    "$phase" "$work/$phase/checkpoint.dcp" "$report_dir" shell _c0 "$route_applicable"
  if [ "$phase" = validate ]; then
    cp "$fixtures/bitstream-drc.rpt" \
      "$report_dir/shell_drc_bitstream_checks_c0.rpt"
  fi
  jq -S . "$report_dir/shell_unconstrained_endpoint_evidence_c0.json" \
    > "$work/generated-endpoints.json"
  jq -S . "$fixtures/unconstrained-endpoint-evidence.json" \
    > "$work/expected-endpoints.json"
  cmp "$work/expected-endpoints.json" "$work/generated-endpoints.json"
  python3 "$signoff_tool" collect \
    --root "$work/$phase" \
    --phase "$phase" \
    --unit config_0 \
    --context "$work/context.json" \
    --checkpoint "$work/$phase/checkpoint.dcp" \
    --report-directory reports \
    --report-prefix shell \
    --report-suffix _c0 \
    --output "$report_dir/shell_strict_signoff_c0.json"
  jq -e --arg phase "$phase" --argjson routed "$route_applicable" '
    .api == "coyote-nix.strict-signoff-evidence/v1"
    and .phase == $phase
    and (.reports.methodology.sha256 | test("^[0-9a-f]{64}$"))
    and (.reports.endpointEvidence.sha256 | test("^[0-9a-f]{64}$"))
    and .sourceIdentity.sourceId == "source-fixture"
    and .sourceIdentity.coyoteSourceId == "coyote-source-fixture"
    and (.artifactIdentity.sha256 | test("^[0-9a-f]{64}$"))
    and .unconstrainedEndpoints == [{
      category: "unconstrained_internal_endpoints",
      endpoint: "fixture/disabled_counter_reg[0]/D",
      reason: "constant-clock",
      clockPins: [{
        pin: "fixture/disabled_counter_reg[0]/C",
        constantValue: "0",
        clocks: []
      }],
      id: .unconstrainedEndpoints[0].id
    }]
    and (.unconstrainedEndpoints[0].id | test("^[0-9a-f]{64}$"))
    and (if $routed == 1 then .routing.routableNets == 10 else .routing == null end)
  ' "$report_dir/shell_strict_signoff_c0.json" >/dev/null
done

printf 'strict signoff report generation contract: PASS\n'
