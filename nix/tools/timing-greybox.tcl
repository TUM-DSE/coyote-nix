# Drive every grey-box output buffer from a flip-flop instead of a constant.
# update_design -buffer_ports ties outputs to VCC/GND, and Vivado then drops
# every shell path through them, so the shell is placed without timing
# toward the application. A register per output, clocked like the shell
# logic it feeds, gives those paths their real timing.
proc coyote_rp_clock_nets {rp} {
  set clocks {}
  foreach p [get_pins -of $rp -filter {DIRECTION == IN}] {
    set c [get_clocks -quiet -of [get_nets -of $p]]
    if {[llength $c] == 0} { continue }
    set inner [get_nets -quiet -of $p -boundary_type lower]
    if {[llength $inner] == 0} {
      set inner [create_net "$rp/coyote_tgb_[get_property REF_PIN_NAME $p]"]
      connect_net -hier -net $inner -objects [list $p]
    }
    lappend clocks [lindex $c 0] $inner
  }
  return $clocks
}
proc coyote_timing_greybox {rp} {
  set clocks [coyote_rp_clock_nets $rp]
  if {[llength $clocks] == 0} { error "$rp has no clock input" }
  set default_clock [lindex $clocks 1]
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
    # Clock of the shell logic this output feeds; aclk when none is found.
    set clock_net $default_clock
    set ends [all_fanout -quiet -endpoints_only -flat $out]
    set end_clocks [get_clocks -quiet -of $ends]
    foreach {clock net} $clocks {
      if {[lsearch -exact $end_clocks $clock] >= 0} { set clock_net $net; break }
    }
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
  return $n
}
