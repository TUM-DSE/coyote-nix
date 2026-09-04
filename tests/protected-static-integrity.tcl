if {$argc != 1} {
    puts stderr "usage: protected-static-integrity.tcl TOOL"
    exit 2
}

proc require {condition message} {
    if {![uplevel 1 [list expr $condition]]} {
        error $message
    }
}

set tool [file normalize [lindex $argv 0]]
set handle [open $tool r]
set source [read $handle]
close $handle
if {![info complete $source]} {
    error "protected-static integrity tool is incomplete"
}
source $tool

foreach required {
    {if {$phase ni {link place route}}}
    {open_checkpoint $reference_checkpoint}
    {set reference_pins [coyote_integrity_capture_partition_pins}
    {set reference_static [coyote_integrity_capture_protected_static}
    {open_checkpoint $candidate_checkpoint}
    {set candidate_pins [coyote_integrity_capture_partition_pins}
    {set candidate_static [coyote_integrity_capture_protected_static}
    {{  "failClosed": true,}}
    {coyote_integrity_write_gate}
    {if {![dict get $comparison accepted]}}
} {
    require {[string first $required $source] >= 0} "missing fail-closed construct: $required"
}

set temporary [file normalize [file join [pwd] protected-static-integrity-fixture]]
file delete -force $temporary
file mkdir $temporary
set regions [list [dict create \
    path inst_shell \
    pblock pblock_inst_shell \
    gridRanges {SLICE_X0Y0:SLICE_X1Y1} \
    derivedRanges {} \
    siteCount 8 \
    pins [list \
        [dict create name inst_shell/input direction IN locations {PPLOC_X0Y0}] \
        [dict create name inst_shell/output direction OUT locations {PPLOC_X0Y1}]]]]
require {[catch {
    coyote_integrity_partition_snapshot_from_regions {} "$temporary/empty-pins.tsv"
}]} "empty partition evidence was accepted"

set duplicate_regions [concat $regions $regions]
require {[catch {
    coyote_integrity_partition_snapshot_from_regions \
        $duplicate_regions "$temporary/duplicate-pins.tsv"
}]} "duplicate partition paths were accepted"

set reference_pins [coyote_integrity_partition_snapshot_from_regions \
    $regions "$temporary/reference-partition-pins.tsv"]
set candidate_pins [coyote_integrity_partition_snapshot_from_regions \
    $regions "$temporary/candidate-partition-pins.tsv"]
set placement_records [list \
    [list cell static/a LUT6 SLICE_X0Y0 A6LUT 1 1] \
    [list cell static/b FDRE SLICE_X0Y1 AFF 1 1]]
set routing_records [list \
    [list net static/clock ROUTED {NODE_A NODE_B}] \
    [list net static/reset ROUTED {NODE_C NODE_D}]]
require {[catch {
    coyote_integrity_static_snapshot_from_records {} $routing_records \
        "$temporary/empty-placement.tsv" "$temporary/nonempty-routing.tsv"
}]} "empty protected-static placement evidence was accepted"
require {[catch {
    coyote_integrity_static_snapshot_from_records $placement_records {} \
        "$temporary/nonempty-placement.tsv" "$temporary/empty-routing.tsv"
}]} "empty protected-static routing evidence was accepted"

set reference_static [coyote_integrity_static_snapshot_from_records \
    $placement_records $routing_records \
    "$temporary/reference-static-placement.tsv" \
    "$temporary/reference-static-routing.tsv"]
set candidate_static [coyote_integrity_static_snapshot_from_records \
    $placement_records $routing_records \
    "$temporary/candidate-static-placement.tsv" \
    "$temporary/candidate-static-routing.tsv"]
set accepted [coyote_integrity_compare \
    $reference_pins $candidate_pins $reference_static $candidate_static]
require {[dict get $accepted accepted]} "identical protected state was rejected"
require {[dict get $accepted reasons] eq {}} "accepted comparison has reasons"

set pin_drift_regions [list [dict create \
    path inst_shell \
    pblock pblock_inst_shell \
    gridRanges {SLICE_X0Y0:SLICE_X1Y1} \
    derivedRanges {} \
    siteCount 8 \
    pins [list \
        [dict create name inst_shell/input direction IN locations {PPLOC_X0Y0}] \
        [dict create name inst_shell/output direction OUT locations {PPLOC_X1Y1}]]]]
set pin_drift [coyote_integrity_partition_snapshot_from_regions \
    $pin_drift_regions "$temporary/pin-drift.tsv"]
set pin_rejected [coyote_integrity_compare \
    $reference_pins $pin_drift $reference_static $candidate_static]
require {![dict get $pin_rejected accepted]} "partition-pin drift was accepted"
require {[lsearch -glob [dict get $pin_rejected reasons] {partition pins * changed}] >= 0} \
    "partition-pin rejection reason is missing"

set placement_drift [coyote_integrity_static_snapshot_from_records \
    [lreplace $placement_records 1 1 [list cell static/b FDRE SLICE_X1Y1 AFF 1 1]] \
    $routing_records \
    "$temporary/placement-drift.tsv" "$temporary/placement-routing.tsv"]
set rejected [coyote_integrity_compare \
    $reference_pins $candidate_pins $reference_static $placement_drift]
require {![dict get $rejected accepted]} "protected placement drift was accepted"
require {[lsearch -glob [dict get $rejected reasons] {protected-static placement * changed}] >= 0} \
    "protected-placement rejection reason is missing"

set route_drift [coyote_integrity_static_snapshot_from_records \
    $placement_records \
    [lreplace $routing_records 0 0 [list net static/clock ROUTED {NODE_A NODE_E}]] \
    "$temporary/route-placement.tsv" "$temporary/route-drift.tsv"]
set rejected [coyote_integrity_compare \
    $reference_pins $candidate_pins $reference_static $route_drift]
require {![dict get $rejected accepted]} "protected routing drift was accepted"
require {[lsearch -glob [dict get $rejected reasons] {protected-static routing * changed}] >= 0} \
    "protected-routing rejection reason is missing"

foreach name {reference.dcp candidate.dcp reference-contract.json} {
    set handle [open "$temporary/$name" w]
    puts $handle $name
    close $handle
}
set digest [string repeat a 64]
coyote_integrity_write_gate \
    "$temporary/gate.json" route u280 ultrascale_plus xcu280-fsvh2892-2L-e \
    2023.2 "$temporary/reference.dcp" "$temporary/candidate.dcp" \
    "$temporary/reference-contract.json" $digest $digest $digest $digest $digest \
    {inst_shell} $reference_pins $candidate_pins $reference_static \
    $candidate_static $accepted
coyote_integrity_write_gate \
    "$temporary/rejected-gate.json" route u280 ultrascale_plus xcu280-fsvh2892-2L-e \
    2023.2 "$temporary/reference.dcp" "$temporary/candidate.dcp" \
    "$temporary/reference-contract.json" $digest $digest $digest $digest $digest \
    {inst_shell} $reference_pins $pin_drift $reference_static \
    $candidate_static $pin_rejected

set unsafe_arguments [list route "$temporary/reference.dcp" \
    "$temporary/candidate.dcp" "$temporary/reference-contract.json" \
    "$temporary/unsafe-output" u280 ultrascale_plus xcu280-fsvh2892-2L-e \
    2023.2 $digest $digest $digest $digest $digest ../inst_shell]
require {[catch {coyote_integrity_main $unsafe_arguments} unsafe_reason]} \
    "unsafe partition path was accepted"
require {[string match {*Unsafe partition path*} $unsafe_reason]} \
    "unsafe partition path had the wrong rejection: $unsafe_reason"

puts "COYOTE_PROTECTED_STATIC_INTEGRITY_PASS gate=$temporary/gate.json"
