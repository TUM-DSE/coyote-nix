# Make grey-boxed applications look like registers to the shell.
# update_design -buffer_ports ties every output to VCC/GND and leaves every
# input on a LUT without loads, so Vivado places the shell without timing
# toward the application. A register behind each output and in front of
# each input, clocked like the shell logic on the other side, gives those
# paths their real timing.

# The leaf pin driving a net, which names it across hierarchy. Cached per
# net segment, since clock nets have many loads.
proc coyote_net_driver {net} {
  global coyote_drivers
  if {![info exists coyote_drivers($net)]} {
    set coyote_drivers($net) [get_pins -quiet -leaf -of $net -filter {DIRECTION == OUT}]
  }
  return $coyote_drivers($net)
}

# Inputs of the partition by the leaf pin driving them.
proc coyote_rp_inputs {rp} {
  set inputs [dict create]
  foreach pin [get_pins -of $rp -filter {DIRECTION == IN}] {
    set driver [coyote_net_driver [get_nets -quiet -of $pin]]
    if {[llength $driver] == 1} { dict set inputs $driver $pin }
  }
  return $inputs
}

# Clock drivers of the first registers behind a pin, counted per driver.
# This walks the netlist, since timing commands see nothing behind a
# constant.
proc coyote_load_clocks {pin {depth 6}} {
  set counts [dict create]
  set frontier [list $pin]
  set seen [dict create]
  while {$depth > 0 && [llength $frontier] > 0} {
    incr depth -1
    set loads [get_pins -quiet -leaf -of [get_nets -quiet -of $frontier] \
      -filter {DIRECTION == IN}]
    set cells {}
    foreach cell [get_cells -quiet -of $loads] {
      if {![dict exists $seen $cell]} { dict set seen $cell 1; lappend cells $cell }
    }
    if {[llength $cells] == 0} { break }
    set registers [get_cells -quiet $cells -filter {IS_SEQUENTIAL}]
    foreach clock_pin [get_pins -quiet -of $registers -filter {IS_CLOCK}] {
      set driver [coyote_net_driver [get_nets -quiet -of $clock_pin]]
      if {[llength $driver] == 1} { dict incr counts $driver }
    }
    set logic [get_cells -quiet $cells -filter {!IS_SEQUENTIAL && PRIMITIVE_LEVEL != MACRO}]
    set frontier [get_pins -quiet -of $logic -filter {DIRECTION == OUT}]
  }
  return $counts
}

# The net inside the partition that carries an input.
proc coyote_rp_inner_net {rp pin} {
  set inner [get_nets -quiet -of $pin -boundary_type lower]
  if {[llength $inner] == 0} {
    set inner [create_net "$rp/coyote_tgb_[get_property REF_PIN_NAME $pin]"]
    connect_net -hier -net $inner -objects [list $pin]
  }
  return $inner
}

# Clock drivers of the registers that start the paths into a pin. Those
# start at real shell registers, so timing fanin sees them.
proc coyote_source_clocks {pin} {
  set counts [dict create]
  foreach clock_pin [all_fanin -quiet -startpoints_only -flat $pin] {
    if {![get_property -quiet IS_CLOCK $clock_pin]} { continue }
    set driver [coyote_net_driver [get_nets -quiet -of $clock_pin]]
    if {[llength $driver] == 1} { dict incr counts $driver }
  }
  return $counts
}

# The partition input whose clock drives most of the given counts.
proc coyote_pick_clock {inputs counts} {
  set clock_pin {}
  set best 0
  dict for {driver count} $counts {
    if {$count > $best && [dict exists $inputs $driver]} {
      set best $count
      set clock_pin [dict get $inputs $driver]
    }
  }
  return $clock_pin
}

proc coyote_timing_greybox {rp} {
  set inputs [coyote_rp_inputs $rp]
  set inner_nets [dict create]
  set vcc [get_nets -quiet "$rp/coyote_tgb_vcc"]
  set gnd [get_nets -quiet "$rp/coyote_tgb_gnd"]
  if {[llength $vcc] == 0} {
    create_cell -reference VCC "$rp/coyote_tgb_vcc_cell"
    create_cell -reference GND "$rp/coyote_tgb_gnd_cell"
    set vcc [create_net "$rp/coyote_tgb_vcc"]
    set gnd [create_net "$rp/coyote_tgb_gnd"]
    connect_net -net $vcc -objects [get_pins "$rp/coyote_tgb_vcc_cell/P"]
    connect_net -net $gnd -objects [get_pins "$rp/coyote_tgb_gnd_cell/G"]
  }
  set n 0
  foreach buf [get_cells -quiet "$rp/HD_PR_Connection_S_OUT_BUF_*"] {
    set in [get_pins -of $buf -filter {DIRECTION == IN}]
    set src [get_nets -of $in]
    if {[get_property TYPE $src] ni {POWER GROUND}} { continue }
    set out [get_pins -of $buf -filter {DIRECTION == OUT}]
    # Clock the register like most of the shell registers this output feeds,
    # through the partition input carrying that clock. Outputs whose loads
    # use no partition clock stay constant, since a register on another
    # clock would add a false path.
    set clock_pin [coyote_pick_clock $inputs [coyote_load_clocks $out]]
    if {$clock_pin eq {}} { continue }
    if {![dict exists $inner_nets $clock_pin]} {
      dict set inner_nets $clock_pin [coyote_rp_inner_net $rp $clock_pin]
    }
    set clock_net [dict get $inner_nets $clock_pin]
    set ff [create_cell -reference FDCE "$rp/coyote_tgb_ff_$n"]
    set q [create_net "$rp/coyote_tgb_q_$n"]
    disconnect_net -net $src -objects $in
    connect_net -net $q -objects [list [get_pins $ff/Q] $in]
    # A toggling register, so no constant reaches the shell.
    set d [create_cell -reference LUT1 "$rp/coyote_tgb_inv_$n"]
    set_property INIT 2'h1 $d
    set dn [create_net "$rp/coyote_tgb_d_$n"]
    connect_net -net $q -objects [get_pins $d/I0]
    connect_net -net $dn -objects [list [get_pins $d/O] [get_pins $ff/D]]
    connect_net -hier -net $clock_net -objects [get_pins $ff/C]
    connect_net -net $vcc -objects [get_pins $ff/CE]
    connect_net -net $gnd -objects [get_pins $ff/CLR]
    set_property DONT_TOUCH true [list $ff $d]
    incr n
  }
  foreach buf [get_cells -quiet "$rp/HD_PR_Connection_S_IN_BUF_*"] {
    set in [get_pins -of $buf -filter {DIRECTION == IN}]
    set out [get_pins -of $buf -filter {DIRECTION == OUT}]
    set net [get_nets -quiet -of $out]
    if {[llength $net] == 0} {
      set net [create_net "$rp/coyote_tgb_in_$n"]
      connect_net -net $net -objects [list $out]
    } elseif {[llength [get_pins -quiet -leaf -of $net -filter {DIRECTION == IN}]] > 0} {
      continue
    }
    set clock_pin [coyote_pick_clock $inputs [coyote_source_clocks $in]]
    if {$clock_pin eq {}} { continue }
    if {![dict exists $inner_nets $clock_pin]} {
      dict set inner_nets $clock_pin [coyote_rp_inner_net $rp $clock_pin]
    }
    set ff [create_cell -reference FDCE "$rp/coyote_tgb_sink_$n"]
    connect_net -net $net -objects [get_pins $ff/D]
    connect_net -hier -net [dict get $inner_nets $clock_pin] -objects [get_pins $ff/C]
    connect_net -net $vcc -objects [get_pins $ff/CE]
    connect_net -net $gnd -objects [get_pins $ff/CLR]
    set_property DONT_TOUCH true $ff
    incr n
  }
  return $n
}
