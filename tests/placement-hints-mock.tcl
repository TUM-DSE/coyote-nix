set ::cells {
    inst_static
    inst_static/frozen/u1
    inst_shell
    inst_shell/qshell
    {inst_shell/qshell/output_queues[0].inst_output_queue}
    {inst_shell/qshell/output_queues[0].inst_output_queue/ff0}
    inst_shell/inst_dynamic/inst_user_wrapper_0
    inst_shell/inst_dynamic/inst_user_wrapper_0/leaf
    inst_shell/fixed_parent
    inst_shell/fixed_parent/leaf
}
set ::props [dict create \
    inst_static/frozen/u1,IS_PRIMITIVE 1 \
    {inst_shell/qshell/output_queues[0].inst_output_queue/ff0,IS_PRIMITIVE} 1 \
    inst_shell/inst_dynamic/inst_user_wrapper_0,HD.RECONFIGURABLE 1 \
    inst_shell/inst_dynamic/inst_user_wrapper_0/leaf,IS_PRIMITIVE 1 \
    inst_shell/fixed_parent/leaf,IS_PRIMITIVE 1 \
    inst_shell/fixed_parent/leaf,IS_LOC_FIXED 1]
set ::pblocks {}
set ::pblock_cells [dict create]
set ::pblock_sites [dict create]

proc get_cells {args} {
    if {[lsearch -exact $args -of_objects] >= 0} {
        set pb [lindex $args [expr {[lsearch -exact $args -of_objects] + 1}]]
        return [dict get $::pblock_cells $pb]
    }
    if {[lsearch -exact $args -hier] >= 0} { return $::cells }
    if {[lsearch -exact $args -quiet] >= 0} { return {} }
    return {}
}
proc get_property {args} {
    if {[lindex $args 0] eq "-quiet"} { set args [lrange $args 1 end] }
    lassign $args property object
    if {$property eq "NAME"} { return $object }
    set key "$object,$property"
    return [expr {[dict exists $::props $key] ? [dict get $::props $key] : ""}]
}
proc get_pblocks {args} { return $::pblocks }
proc get_sites {args} {
    if {[lsearch -exact $args -of_objects] >= 0} {
        set pb [lindex $args [expr {[lsearch -exact $args -of_objects] + 1}]]
        return [dict get $::pblock_sites $pb]
    }
    set selector [lindex $args end]
    if {$selector in {SLICE_X10Y20 SLICE_X11Y21 SLICE_X12Y22}} { return [list $selector] }
    return {}
}
proc create_pblock {name} { lappend ::pblocks $name; dict set ::pblock_cells $name {}; dict set ::pblock_sites $name {}; return $name }
proc set_property {property value object} { dict set ::props "$object,$property" $value }
proc resize_pblock {pb option site_list} {
    if {$option ne "-add" || ![dict exists $::pblock_cells $pb]} {
        error "resize_pblock expects an existing pblock followed by -add and sites"
    }
    dict set ::pblock_sites $pb $site_list
}
proc add_cells_to_pblock {pb cell_list} {
    if {![dict exists $::pblock_cells $pb]} {
        error "add_cells_to_pblock expects an existing pblock followed by cells"
    }
    dict set ::pblock_cells $pb $cell_list
}

source [lindex $argv 0]
set ::coyote_static_cell_names {inst_static/frozen/u1}
set ::coyote_placement_hint_groups [list [list queue0 [list {inst_shell/qshell/output_queues[0].inst_output_queue}] [list SLICE_X10Y20]]]
coyote_apply_placement_hints
if {[llength $::pblocks] != 1 || [get_property IS_SOFT [lindex $::pblocks 0]] ne "true"} {
    error "valid placement hint did not create a SOFT pblock"
}
set placed_cells [dict get $::pblock_cells [lindex $::pblocks 0]]
if {[lsearch -exact $placed_cells {inst_shell/qshell/output_queues[0].inst_output_queue/ff0}] < 0} {
    error "hierarchical selector did not expand to its primitive leaf"
}

set ::pblocks {}
set ::coyote_placement_hint_required 1
coyote_apply_placement_hints
if {[get_property IS_SOFT [lindex $::pblocks 0]] ne "false"} {
    error "required placement did not enforce the admitted region"
}

proc expect_reject {groups label} {
    set ::coyote_placement_hint_groups $groups
    if {![catch {coyote_apply_placement_hints} message]} { error "$label was unexpectedly accepted" }
}
expect_reject [list [list stat [list inst_static/frozen/u1] [list SLICE_X10Y20]]] "static cell"
expect_reject [list [list rp [list inst_shell/inst_dynamic/inst_user_wrapper_0/leaf] [list SLICE_X11Y21]]] "RP descendant"
expect_reject [list [list fixed [list inst_shell/fixed_parent] [list SLICE_X11Y21]]] "fixed descendant"
expect_reject [list [list duplicate [list inst_shell/qshell] [list SLICE_X11Y21]]] "existing pblock overlap"

set ::pblocks {coyote_hint_collision}
expect_reject [list [list collision [list {inst_shell/qshell/output_queues[0].inst_output_queue}] [list SLICE_X12Y22]]] "pblock name collision"
set ::pblocks {existing}
dict set ::pblock_sites existing {SLICE_X12Y22}
expect_reject [list [list collision [list {inst_shell/qshell/output_queues[0].inst_output_queue}] [list SLICE_X12Y22]]] "site collision"

set ::pblocks {}
dict set ::pblock_sites existing {}
expect_reject [list \
    [list parent [list inst_shell/qshell] [list SLICE_X10Y20]] \
    [list child [list {inst_shell/qshell/output_queues[0].inst_output_queue}] [list SLICE_X11Y21]]] "hierarchical selector overlap"
# Static opt-in is limited to unplaced non-clock descendants; it cannot move
# a previously placed reference even when its fixed-location flag is clear.
lappend ::cells inst_static/logic inst_static/logic/ff
set ::pblocks {}
dict set ::props inst_static/logic/ff,IS_PRIMITIVE 1
set static_group [list [list static_logic [list inst_static/logic] [list SLICE_X11Y21]]]
set ::coyote_placement_hint_unplaced_static 0
expect_reject $static_group "static default remains protected"
set ::coyote_placement_hint_unplaced_static 1
set ::coyote_placement_hint_groups $static_group
coyote_apply_placement_hints
if {[dict get $::pblock_cells coyote_hint_static_logic] ne "inst_static/logic/ff"} {
    error "unplaced static selection was not applied"
}
set ::pblocks {}
expect_reject $static_group "static capability does not leak to the next input"
proc expect_static_reject {groups label} {
    set ::coyote_placement_hint_unplaced_static 1
    expect_reject $groups $label
}
expect_static_reject [list [list whole_static [list inst_static] [list SLICE_X11Y21]]] "static insertion root"
dict set ::props inst_static/logic/ff,LOC SLICE_X11Y21
expect_static_reject $static_group "already placed static cell"
dict set ::props inst_static/logic/ff,LOC ""
dict set ::props inst_static/logic/ff,PRIMITIVE_GROUP CLOCK
expect_static_reject $static_group "unplaced static clock resource"
dict set ::props inst_static/logic/ff,PRIMITIVE_GROUP LUT
dict set ::props inst_static/logic,IS_LOC_FIXED 1
expect_static_reject $static_group "fixed static ancestor"
puts "placement hint Tcl admission behavior passed"
