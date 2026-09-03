################################################################################
# Retain the complete report set consumed by coyote-nix strict physical signoff.
################################################################################

if {$argc != 6} {
    puts stderr "usage: coyote-signoff-reports.tcl PHASE CHECKPOINT REPORT_DIR REPORT_PREFIX REPORT_SUFFIX ROUTE_APPLICABLE"
    exit 2
}

lassign $argv phase checkpoint report_dir report_prefix report_suffix route_applicable
if {$phase ni {link place route validate}} {
    puts stderr "unsupported strict-signoff report phase: $phase"
    exit 2
}
if {$route_applicable ni {0 1}} {
    puts stderr "route applicability must be 0 or 1"
    exit 2
}
if {($phase in {route validate}) != $route_applicable} {
    puts stderr "route applicability does not match phase $phase"
    exit 2
}

proc signoff_report_path {report_dir report_prefix report_kind report_suffix} {
    return [file join $report_dir "${report_prefix}_${report_kind}${report_suffix}.rpt"]
}

proc signoff_json_path {report_dir report_prefix report_kind report_suffix} {
    return [file join $report_dir "${report_prefix}_${report_kind}${report_suffix}.json"]
}

proc endpoint_reason {category description} {
    set lowered [string tolower $description]
    if {$category eq "no_clock"} {
        return "no-clock"
    }
    if {[string first "due to constant clock" $lowered] >= 0} {
        return "constant-clock"
    }
    if {[string first "not constrained for maximum delay" $lowered] >= 0} {
        return "missing-max-delay"
    }
    error "unrecognized $category endpoint group: $description"
}

proc parse_endpoint_section {lines category} {
    set starts {}
    set pattern [format {^[0-9]+\.\s+checking\s+%s\s+\(([0-9]+)\)\s*$} $category]
    for {set index 0} {$index < [llength $lines]} {incr index} {
        if {[regexp $pattern [string trim [lindex $lines $index]] -> count]} {
            lappend starts [list $index $count]
        }
    }
    if {[llength $starts] == 0} {
        error "check_timing report omits $category"
    }
    lassign [lindex $starts end] start expected_count
    set end [llength $lines]
    set next_section {^[0-9]+\.\s+checking\s+[a-z0-9_]+\s+\([0-9]+\)\s*$}
    for {set index [expr {$start + 1}]} {$index < [llength $lines]} {incr index} {
        if {[regexp $next_section [string trim [lindex $lines $index]]]} {
            set end $index
            break
        }
    }

    set description ""
    set records {}
    for {set index [expr {$start + 1}]} {$index < $end} {incr index} {
        set raw [lindex $lines $index]
        set stripped [string trim $raw]
        if {[string match -nocase "There are *" $stripped]} {
            set description $stripped
            continue
        }
        if {$stripped ne "" && $raw eq [string trimleft $raw] &&
                [string first "/" $stripped] >= 0 &&
                ![string match "-*" $stripped]} {
            lappend records [dict create \
                category $category \
                endpoint $stripped \
                reason [endpoint_reason $category $description]]
        }
    }
    if {[llength $records] != $expected_count} {
        error "check_timing $category declares $expected_count endpoints but lists [llength $records]"
    }
    return $records
}

proc compare_endpoint_records {left right} {
    set left_key "[dict get $left category]\u0000[dict get $left endpoint]\u0000[dict get $left reason]"
    set right_key "[dict get $right category]\u0000[dict get $right endpoint]\u0000[dict get $right reason]"
    return [string compare $left_key $right_key]
}

proc json_escape {value} {
    set escaped ""
    foreach character [split $value ""] {
        switch -- $character {
            "\\" { append escaped "\\\\" }
            "\"" { append escaped "\\\"" }
            "\b" { append escaped "\\b" }
            "\f" { append escaped "\\f" }
            "\n" { append escaped "\\n" }
            "\r" { append escaped "\\r" }
            "\t" { append escaped "\\t" }
            default {
                scan $character %c codepoint
                if {$codepoint < 32} {
                    append escaped [format "\\u%04x" $codepoint]
                } else {
                    append escaped $character
                }
            }
        }
    }
    return $escaped
}

proc json_string {value} {
    return "\"[json_escape $value]\""
}

proc json_string_array {values} {
    set encoded {}
    foreach value $values {
        lappend encoded [json_string $value]
    }
    return "\[[join $encoded ,]\]"
}

proc exact_endpoint_pin {endpoint} {
    set exact {}
    foreach pin [get_pins -quiet $endpoint] {
        if {[get_property NAME $pin] eq $endpoint} {
            lappend exact $pin
        }
    }
    if {[llength $exact] != 1} {
        error "expected exactly one endpoint pin named $endpoint, found [llength $exact]"
    }
    return [lindex $exact 0]
}

proc endpoint_clock_pins {endpoint} {
    set endpoint_pin [exact_endpoint_pin $endpoint]
    set cells [get_cells -quiet -of_objects $endpoint_pin]
    if {[llength $cells] != 1} {
        error "expected exactly one cell for endpoint $endpoint, found [llength $cells]"
    }

    set clock_records {}
    foreach pin [get_pins -quiet -of_objects [lindex $cells 0]] {
        set is_clock [get_property -quiet IS_CLOCK $pin]
        if {$is_clock ni {1 true TRUE}} {
            continue
        }
        set pin_name [get_property NAME $pin]
        set constant_value [get_property -quiet CONSTANT_VALUE $pin]
        set clock_names {}
        foreach clock [get_clocks -quiet -of_objects $pin] {
            lappend clock_names [get_property NAME $clock]
        }
        set clock_names [lsort -ascii -unique $clock_names]
        lappend clock_records [dict create \
            pin $pin_name \
            constantValue $constant_value \
            clocks $clock_names]
    }
    return [lsort -ascii -index 1 $clock_records]
}

proc write_endpoint_evidence {check_timing_path output_path} {
    set input [open $check_timing_path r]
    fconfigure $input -encoding utf-8 -translation auto
    set lines [split [read $input] "\n"]
    close $input

    set records [concat \
        [parse_endpoint_section $lines no_clock] \
        [parse_endpoint_section $lines unconstrained_internal_endpoints]]
    set records [lsort -command compare_endpoint_records $records]
    set seen {}
    set encoded_records {}
    foreach record $records {
        set category [dict get $record category]
        set endpoint [dict get $record endpoint]
        set reason [dict get $record reason]
        set key "$category\u0000$endpoint"
        if {[dict exists $seen $key]} {
            error "duplicate unconstrained endpoint in check_timing report: $category $endpoint"
        }
        dict set seen $key 1

        set encoded_clock_pins {}
        foreach clock_pin [endpoint_clock_pins $endpoint] {
            lappend encoded_clock_pins [format \
                {{"pin":%s,"constantValue":%s,"clocks":%s}} \
                [json_string [dict get $clock_pin pin]] \
                [json_string [dict get $clock_pin constantValue]] \
                [json_string_array [dict get $clock_pin clocks]]]
        }
        lappend encoded_records [format \
            {{"category":%s,"endpoint":%s,"reason":%s,"clockPins":[%s]}} \
            [json_string $category] \
            [json_string $endpoint] \
            [json_string $reason] \
            [join $encoded_clock_pins ,]]
    }

    set output [open $output_path w]
    fconfigure $output -encoding utf-8 -translation lf
    puts $output [format \
        {{"schemaVersion":1,"api":"coyote-nix.strict-signoff-endpoints/v1","endpoints":[%s]}} \
        [join $encoded_records ,]]
    close $output
}

if {[catch {
    if {![file isfile $checkpoint]} {
        error "strict-signoff checkpoint does not exist: $checkpoint"
    }
    file mkdir $report_dir
    open_checkpoint $checkpoint

    # Run methodology first so the subsequent timing summary embeds its result.
    report_methodology -file [signoff_report_path \
        $report_dir $report_prefix methodology $report_suffix]
    report_exceptions -file [signoff_report_path \
        $report_dir $report_prefix timing_exceptions $report_suffix]
    report_bus_skew -file [signoff_report_path \
        $report_dir $report_prefix bus_skew $report_suffix]
    report_clock_interaction -file [signoff_report_path \
        $report_dir $report_prefix clock_interaction $report_suffix]
    set unconstrained_path [signoff_report_path \
        $report_dir $report_prefix unconstrained_endpoints $report_suffix]
    check_timing -verbose -file $unconstrained_path
    write_endpoint_evidence $unconstrained_path [signoff_json_path \
        $report_dir $report_prefix unconstrained_endpoint_evidence $report_suffix]
    report_drc -name "${report_prefix}_strict_signoff${report_suffix}" \
        -file [signoff_report_path $report_dir $report_prefix drc $report_suffix]
    report_timing_summary -delay_type min_max -max_paths 20 \
        -file [signoff_report_path \
            $report_dir $report_prefix timing_summary $report_suffix]
    if {$route_applicable} {
        report_route_status -ignore_cache -file [signoff_report_path \
            $report_dir $report_prefix route_status $report_suffix]
    }

    close_project
} error_message]} {
    catch {close_project}
    puts stderr "strict-signoff report generation failed: $error_message"
    exit 1
}

exit 0
