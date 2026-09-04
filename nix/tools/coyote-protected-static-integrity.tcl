######################################################################################
# Fail-closed partition-pin and protected-static checkpoint comparison.
######################################################################################

proc coyote_integrity_json_escape {value} {
    return [string map [list \\ \\\\ \" \\" \n \\n \r \\r \t \\t] $value]
}

proc coyote_integrity_json_string {value} {
    return "\"[coyote_integrity_json_escape $value]\""
}

proc coyote_integrity_json_bool {value} {
    return [expr {$value ? "true" : "false"}]
}

proc coyote_integrity_json_string_array {values} {
    set encoded {}
    foreach value $values {
        lappend encoded [coyote_integrity_json_string $value]
    }
    return "\[[join $encoded {, }]\]"
}

proc coyote_integrity_is_true {value} {
    return [expr {[string tolower [string trim $value]] in {1 true yes on}}]
}

proc coyote_integrity_property {object property {required false}} {
    if {[catch {set value [get_property $property $object]} reason]} {
        if {$required} {
            error "Unable to read $property from $object: $reason"
        }
        return ""
    }
    if {$required && [string trim $value] eq ""} {
        error "Required property $property is empty on $object"
    }
    return $value
}

proc coyote_integrity_sha256_file {path} {
    if {![file isfile $path] || [file type $path] ne "file"} {
        error "Cannot fingerprint non-regular file: $path"
    }
    if {[catch {set output [exec sha256sum -- $path]} reason]} {
        error "Unable to fingerprint $path: $reason"
    }
    set digest [string tolower [lindex $output 0]]
    if {![regexp {^[0-9a-f]{64}$} $digest]} {
        error "sha256sum returned a malformed digest for $path: $digest"
    }
    return $digest
}

proc coyote_integrity_write_records {path records} {
    file mkdir [file dirname $path]
    set normalized {}
    foreach record $records {
        lappend normalized [list {*}$record]
    }
    set fd [open $path w]
    fconfigure $fd -encoding utf-8 -translation lf
    foreach record [lsort -ascii $normalized] {
        puts $fd $record
    }
    close $fd
}

proc coyote_integrity_density_ppm {locations sites} {
    if {![string is integer -strict $locations] || $locations < 0 ||
        ![string is integer -strict $sites] || $sites <= 0} {
        error "Partition-pin density requires non-negative locations and positive pblock sites"
    }
    return [expr {($locations * 1000000 + ($sites / 2)) / $sites}]
}

proc coyote_integrity_partition_locations {pin} {
    foreach property {HD.PARTPIN_LOCS HD.PARTPIN_LOC} {
        if {![catch {set value [get_property $property $pin]}] &&
            [string trim $value] ne ""} {
            set locations {}
            foreach location $value {
                if {[string trim $location] ne ""} {
                    lappend locations $location
                }
            }
            if {[llength $locations] > 0} {
                return [lsort -ascii -unique $locations]
            }
        }
    }
    error "Partition pin $pin has no physical HD.PARTPIN_LOCS location"
}

proc coyote_integrity_partition_snapshot_from_regions {regions output_path} {
    if {[llength $regions] == 0} {
        error "Checkpoint has no declared reconfigurable partition"
    }

    set records [list [list format coyote-protected-partition-pins-v1]]
    set logical_pin_count 0
    set physical_location_count 0
    set pblock_site_count 0
    set all_locations {}
    set seen_paths {}

    set decorated_regions {}
    foreach region $regions {
        foreach required {path pblock gridRanges derivedRanges siteCount pins} {
            if {![dict exists $region $required]} {
                error "Partition-region record is missing $required"
            }
        }
        lappend decorated_regions [list [dict get $region path] $region]
    }
    foreach decorated [lsort -ascii -index 0 $decorated_regions] {
        set region [lindex $decorated 1]
        set path [dict get $region path]
        if {$path eq "" || $path in $seen_paths} {
            error "Partition path is empty or duplicated: $path"
        }
        lappend seen_paths $path
        set pblock [dict get $region pblock]
        set grid_ranges [lsort -ascii -unique [dict get $region gridRanges]]
        set derived_ranges [lsort -ascii -unique [dict get $region derivedRanges]]
        set site_count [dict get $region siteCount]
        if {$pblock eq "" || ![string is integer -strict $site_count] || $site_count <= 0} {
            error "Partition $path has no physical pblock sites"
        }
        if {[llength $grid_ranges] == 0 && [llength $derived_ranges] == 0} {
            error "Partition $path has no physical pblock ranges"
        }

        set pin_count 0
        set seen_pins {}
        foreach pin [dict get $region pins] {
            foreach required {name direction locations} {
                if {![dict exists $pin $required]} {
                    error "Partition pin record in $path is missing $required"
                }
            }
            set name [dict get $pin name]
            set direction [string toupper [dict get $pin direction]]
            set locations [lsort -ascii -unique [dict get $pin locations]]
            if {$name eq "" || $name in $seen_pins ||
                $direction ni {IN OUT INOUT} || [llength $locations] == 0} {
                error "Partition $path has a malformed or duplicate physical pin record"
            }
            lappend seen_pins $name
            lappend records [list pin $path $name $direction {*}$locations]
            incr pin_count
            incr physical_location_count [llength $locations]
            foreach location $locations {
                lappend all_locations $location
            }
        }
        if {$pin_count <= 0} {
            error "Partition $path has no physical partition pins"
        }
        lappend records [list region $path $pblock $site_count \
            [list {*}$grid_ranges] [list {*}$derived_ranges]]
        incr logical_pin_count $pin_count
        incr pblock_site_count $site_count
    }

    if {$logical_pin_count <= 0 || $physical_location_count <= 0 ||
        $pblock_site_count <= 0} {
        error "Partition-pin evidence is empty"
    }
    coyote_integrity_write_records $output_path $records
    return [dict create \
        objectCount $logical_pin_count \
        recordCount [llength $records] \
        physicalLocationCount $physical_location_count \
        uniquePhysicalLocationCount [llength [lsort -ascii -unique $all_locations]] \
        pblockSiteCount $pblock_site_count \
        locationsPerMillionPblockSites \
            [coyote_integrity_density_ppm $physical_location_count $pblock_site_count] \
        sha256 [coyote_integrity_sha256_file $output_path]]
}

proc coyote_integrity_capture_partition_pins {partition_paths output_path} {
    set regions {}
    foreach path $partition_paths {
        set cells [get_cells -quiet $path]
        if {[llength $cells] != 1} {
            error "Expected exactly one reconfigurable partition $path, found [llength $cells]"
        }
        set cell [lindex $cells 0]
        set tail [lindex [split $path /] end]
        set pblock_name "pblock_$tail"
        set pblocks [get_pblocks -quiet $pblock_name]
        if {[llength $pblocks] != 1} {
            error "Expected exactly one application pblock $pblock_name, found [llength $pblocks]"
        }
        set pblock [lindex $pblocks 0]
        set pins {}
        foreach pin [get_pins -quiet -of_objects $cell] {
            lappend pins [dict create \
                name [coyote_integrity_property $pin NAME true] \
                direction [coyote_integrity_property $pin DIRECTION true] \
                locations [coyote_integrity_partition_locations $pin]]
        }
        lappend regions [dict create \
            path $path \
            pblock $pblock_name \
            gridRanges [coyote_integrity_property $pblock GRID_RANGES] \
            derivedRanges [coyote_integrity_property $pblock DERIVED_RANGES] \
            siteCount [llength [get_sites -quiet -of_objects $pblock]] \
            pins $pins]
    }
    return [coyote_integrity_partition_snapshot_from_regions $regions $output_path]
}

proc coyote_integrity_is_partition_object {name partition_paths} {
    foreach path $partition_paths {
        if {$name eq $path || [string first "${path}/" $name] == 0} {
            return true
        }
    }
    return false
}

proc coyote_integrity_static_snapshot_from_records {
    placement_records routing_records placement_path routing_path
} {
    if {[llength $placement_records] == 0} {
        error "Protected-static placement set is empty"
    }
    if {[llength $routing_records] == 0} {
        error "Protected-static routing set is empty"
    }
    coyote_integrity_write_records $placement_path \
        [linsert $placement_records 0 [list format coyote-protected-static-placement-v1]]
    coyote_integrity_write_records $routing_path \
        [linsert $routing_records 0 [list format coyote-protected-static-routing-v1]]
    return [dict create \
        placement [dict create \
            objectCount [llength $placement_records] \
            recordCount [expr {[llength $placement_records] + 1}] \
            sha256 [coyote_integrity_sha256_file $placement_path]] \
        routing [dict create \
            objectCount [llength $routing_records] \
            recordCount [expr {[llength $routing_records] + 1}] \
            sha256 [coyote_integrity_sha256_file $routing_path]]]
}

proc coyote_integrity_capture_protected_static {
    partition_paths placement_path routing_path
} {
    set placement_records {}
    foreach cell [get_cells -quiet -hierarchical \
        -filter {IS_LOC_FIXED == 1 || IS_BEL_FIXED == 1}] {
        set name [coyote_integrity_property $cell NAME true]
        if {[coyote_integrity_is_partition_object $name $partition_paths]} {
            continue
        }
        set loc_fixed [coyote_integrity_is_true \
            [coyote_integrity_property $cell IS_LOC_FIXED]]
        set bel_fixed [coyote_integrity_is_true \
            [coyote_integrity_property $cell IS_BEL_FIXED]]
        if {!$loc_fixed && !$bel_fixed} {
            continue
        }
        lappend placement_records [list \
            cell $name \
            [coyote_integrity_property $cell REF_NAME] \
            [coyote_integrity_property $cell LOC] \
            [coyote_integrity_property $cell BEL] \
            $loc_fixed $bel_fixed]
    }

    set routing_records {}
    foreach net [get_nets -quiet -hierarchical -filter {IS_ROUTE_FIXED == 1}] {
        set name [coyote_integrity_property $net NAME true]
        if {[coyote_integrity_is_partition_object $name $partition_paths]} {
            continue
        }
        if {![coyote_integrity_is_true \
            [coyote_integrity_property $net IS_ROUTE_FIXED]]} {
            continue
        }
        lappend routing_records [list \
            net $name \
            [coyote_integrity_property $net ROUTE_STATUS] \
            [coyote_integrity_property $net FIXED_ROUTE]]
    }

    return [coyote_integrity_static_snapshot_from_records \
        $placement_records $routing_records $placement_path $routing_path]
}

proc coyote_integrity_compare {reference_pins candidate_pins reference_static candidate_static} {
    set reasons {}
    foreach key {
        objectCount recordCount physicalLocationCount uniquePhysicalLocationCount
        pblockSiteCount locationsPerMillionPblockSites sha256
    } {
        if {[dict get $reference_pins $key] ne [dict get $candidate_pins $key]} {
            lappend reasons "partition pins $key changed"
        }
    }
    foreach kind {placement routing} {
        foreach key {objectCount recordCount sha256} {
            if {[dict get $reference_static $kind $key] ne
                [dict get $candidate_static $kind $key]} {
                lappend reasons "protected-static $kind $key changed"
            }
        }
    }
    return [dict create accepted [expr {[llength $reasons] == 0}] reasons $reasons]
}

proc coyote_integrity_write_snapshot {fd indent value} {
    puts $fd "${indent}{"
    puts $fd "${indent}  \"objectCount\": [dict get $value objectCount],"
    puts $fd "${indent}  \"recordCount\": [dict get $value recordCount],"
    if {[dict exists $value physicalLocationCount]} {
        puts $fd "${indent}  \"physicalLocationCount\": [dict get $value physicalLocationCount],"
        puts $fd "${indent}  \"uniquePhysicalLocationCount\": [dict get $value uniquePhysicalLocationCount],"
        puts $fd "${indent}  \"pblockSiteCount\": [dict get $value pblockSiteCount],"
        puts $fd "${indent}  \"locationsPerMillionPblockSites\": [dict get $value locationsPerMillionPblockSites],"
    }
    puts $fd "${indent}  \"sha256\": [coyote_integrity_json_string [dict get $value sha256]]"
    puts -nonewline $fd "${indent}}"
}

proc coyote_integrity_write_pair {fd indent reference candidate} {
    set identical [expr {$reference eq $candidate}]
    puts $fd "${indent}{"
    puts $fd "${indent}  \"reference\": "
    coyote_integrity_write_snapshot $fd "${indent}  " $reference
    puts $fd ","
    puts $fd "${indent}  \"candidate\": "
    coyote_integrity_write_snapshot $fd "${indent}  " $candidate
    puts $fd ","
    puts $fd "${indent}  \"identical\": [coyote_integrity_json_bool $identical]"
    puts -nonewline $fd "${indent}}"
}

proc coyote_integrity_write_gate {
    path phase board architecture part tool_version reference_checkpoint
    candidate_checkpoint reference_contract reference_contract_id base_source_id
    candidate_source_id effective_source_id delta_contract_id partition_paths
    reference_pins candidate_pins reference_static candidate_static comparison
} {
    set reference_checkpoint_sha256 [coyote_integrity_sha256_file $reference_checkpoint]
    set candidate_checkpoint_sha256 [coyote_integrity_sha256_file $candidate_checkpoint]
    set reference_contract_sha256 [coyote_integrity_sha256_file $reference_contract]
    set accepted [dict get $comparison accepted]
    set outcome [expr {$accepted ? "accepted" : "rejected"}]

    set evidence [list \
        [list reference-partition-pins reference-partition-pins.tsv [dict get $reference_pins sha256]] \
        [list candidate-partition-pins candidate-partition-pins.tsv [dict get $candidate_pins sha256]] \
        [list reference-static-placement reference-static-placement.tsv [dict get $reference_static placement sha256]] \
        [list candidate-static-placement candidate-static-placement.tsv [dict get $candidate_static placement sha256]] \
        [list reference-static-routing reference-static-routing.tsv [dict get $reference_static routing sha256]] \
        [list candidate-static-routing candidate-static-routing.tsv [dict get $candidate_static routing sha256]]]

    set fd [open $path w]
    fconfigure $fd -encoding utf-8 -translation lf
    puts $fd "{"
    puts $fd {  "schemaVersion": 1,}
    puts $fd {  "api": "coyote-nix.protected-static-integrity/v1",}
    puts $fd {  "kind": "coyote-protected-static-integrity",}
    puts $fd {  "failClosed": true,}
    puts $fd "  \"outcome\": [coyote_integrity_json_string $outcome],"
    puts $fd "  \"phase\": [coyote_integrity_json_string $phase],"
    puts $fd "  \"board\": [coyote_integrity_json_string $board],"
    puts $fd "  \"fpgaArchitecture\": [coyote_integrity_json_string $architecture],"
    puts $fd "  \"fpgaPart\": [coyote_integrity_json_string $part],"
    puts $fd "  \"vivadoVersion\": [coyote_integrity_json_string $tool_version],"
    puts $fd "  \"partitionPaths\": [coyote_integrity_json_string_array $partition_paths],"
    puts $fd "  \"reference\": {"
    puts $fd "    \"checkpointSha256\": [coyote_integrity_json_string $reference_checkpoint_sha256],"
    puts $fd "    \"contractSha256\": [coyote_integrity_json_string $reference_contract_sha256],"
    puts $fd "    \"contractId\": [coyote_integrity_json_string $reference_contract_id],"
    puts $fd "    \"baseCoyoteSourceId\": [coyote_integrity_json_string $base_source_id]"
    puts $fd "  },"
    puts $fd "  \"candidate\": {"
    puts $fd "    \"checkpointSha256\": [coyote_integrity_json_string $candidate_checkpoint_sha256],"
    puts $fd "    \"candidateCoyoteSourceId\": [coyote_integrity_json_string $candidate_source_id],"
    puts $fd "    \"effectiveCoyoteSourceId\": [coyote_integrity_json_string $effective_source_id],"
    puts $fd "    \"sourceDeltaContractId\": [coyote_integrity_json_string $delta_contract_id]"
    puts $fd "  },"
    puts $fd "  \"partitionPins\": "
    coyote_integrity_write_pair $fd "  " $reference_pins $candidate_pins
    puts $fd ","
    puts $fd "  \"protectedStatic\": {"
    puts $fd "    \"scope\": [coyote_integrity_json_string "outside:[join $partition_paths ,]"],"
    puts $fd "    \"placement\": "
    coyote_integrity_write_pair $fd "    " \
        [dict get $reference_static placement] [dict get $candidate_static placement]
    puts $fd ","
    puts $fd "    \"routing\": "
    coyote_integrity_write_pair $fd "    " \
        [dict get $reference_static routing] [dict get $candidate_static routing]
    puts $fd ""
    puts $fd "  },"
    puts $fd "  \"evidence\": \["
    for {set index 0} {$index < [llength $evidence]} {incr index} {
        lassign [lindex $evidence $index] role evidence_path sha256
        set comma [expr {$index + 1 < [llength $evidence] ? "," : ""}]
        puts $fd "    {\"role\": [coyote_integrity_json_string $role], \"path\": [coyote_integrity_json_string $evidence_path], \"sha256\": [coyote_integrity_json_string $sha256]}$comma"
    }
    puts $fd "  \],"
    puts $fd "  \"reasons\": [coyote_integrity_json_string_array [dict get $comparison reasons]]"
    puts $fd "}"
    close $fd
}

proc coyote_integrity_main {arguments} {
    if {[llength $arguments] < 15} {
        error "usage: coyote-protected-static-integrity.tcl PHASE REFERENCE_DCP CANDIDATE_DCP REFERENCE_CONTRACT OUTPUT_DIR BOARD ARCHITECTURE PART VIVADO_VERSION REFERENCE_ID BASE_SOURCE_ID CANDIDATE_SOURCE_ID EFFECTIVE_SOURCE_ID DELTA_CONTRACT_ID PARTITION..."
    }
    lassign $arguments phase reference_checkpoint candidate_checkpoint \
        reference_contract output_dir board architecture part expected_version \
        reference_contract_id base_source_id candidate_source_id \
        effective_source_id delta_contract_id
    set partition_paths [lrange $arguments 14 end]

    if {$phase ni {link place route}} {
        error "Unsupported protected-static integrity phase: $phase"
    }
    foreach {label value} [list \
        reference-contract-id $reference_contract_id \
        base-source-id $base_source_id \
        candidate-source-id $candidate_source_id \
        effective-source-id $effective_source_id \
        delta-contract-id $delta_contract_id] {
        if {![regexp {^[0-9a-f]{64}$} $value]} {
            error "$label must be a lowercase SHA-256 digest"
        }
    }
    if {[llength $partition_paths] == 0 ||
        $partition_paths ne [lsort -ascii -unique $partition_paths]} {
        error "Partition paths must be nonempty, unique, and bytewise sorted"
    }
    foreach path $partition_paths {
        if {$path eq "" || [string index $path 0] eq "/" ||
            [string index $path end] eq "/" || [string first "\\" $path] >= 0 ||
            [regexp {(^|/)\.\.?(/|$)} $path] ||
            ![regexp {^[[:alnum:]_.+\[\]-]+(/[[:alnum:]_.+\[\]-]+)*$} $path]} {
            error "Unsafe partition path: $path"
        }
    }
    foreach path [list $reference_checkpoint $candidate_checkpoint $reference_contract] {
        if {![file isfile $path] || [file type $path] ne "file"} {
            error "Protected-static integrity input is not a regular file: $path"
        }
    }
    if {[file exists $output_dir]} {
        error "Protected-static integrity output already exists: $output_dir"
    }
    set observed_version [version -short]
    if {$observed_version ne $expected_version} {
        error "Vivado version mismatch: expected $expected_version, got $observed_version"
    }
    file mkdir $output_dir

    open_checkpoint $reference_checkpoint
    set reference_pins [coyote_integrity_capture_partition_pins \
        $partition_paths "$output_dir/reference-partition-pins.tsv"]
    set reference_static [coyote_integrity_capture_protected_static \
        $partition_paths \
        "$output_dir/reference-static-placement.tsv" \
        "$output_dir/reference-static-routing.tsv"]
    close_project

    open_checkpoint $candidate_checkpoint
    set candidate_pins [coyote_integrity_capture_partition_pins \
        $partition_paths "$output_dir/candidate-partition-pins.tsv"]
    set candidate_static [coyote_integrity_capture_protected_static \
        $partition_paths \
        "$output_dir/candidate-static-placement.tsv" \
        "$output_dir/candidate-static-routing.tsv"]
    close_project

    set comparison [coyote_integrity_compare \
        $reference_pins $candidate_pins $reference_static $candidate_static]
    coyote_integrity_write_gate \
        "$output_dir/gate.json" $phase $board $architecture $part $observed_version \
        $reference_checkpoint $candidate_checkpoint $reference_contract \
        $reference_contract_id $base_source_id $candidate_source_id \
        $effective_source_id $delta_contract_id $partition_paths \
        $reference_pins $candidate_pins $reference_static $candidate_static $comparison
    if {![dict get $comparison accepted]} {
        error "Protected-static integrity rejected $phase: [join [dict get $comparison reasons] {; }]"
    }
}

if {[file normalize [info script]] eq [file normalize $argv0]} {
    if {[catch {coyote_integrity_main $argv} reason options]} {
        catch {close_project}
        puts stderr "ERROR: $reason"
        if {[dict exists $options -errorinfo]} {
            puts stderr [dict get $options -errorinfo]
        }
        exit 1
    }
    exit 0
}
