# One reconfigurable vFPGA region for U280 shells. Fifteen clock regions in
# the middle SLR give about 190K LUTs and 160 RAMB36, well above the largest
# example, and sit next to the static region's host interface. The shell keeps
# the bottom SLR for the HBM ports it drives and the top SLR for the network
# cages, each one SLR crossing away from the application. A larger region
# pushed the shell's HBM logic away from its ports and missed timing.

create_pblock pblock_inst_user_wrapper_0
add_cells_to_pblock [get_pblocks pblock_inst_user_wrapper_0] [get_cells -quiet [list inst_shell/inst_dynamic/inst_user_wrapper_0]]
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add {CLOCKREGION_X1Y4:CLOCKREGION_X5Y6}
# Applications need only fabric, so hard blocks and I/O in these clock regions
# stay with the shell; otherwise DFX validation rejects the app link.
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -remove \
  [get_sites -of [get_pblocks pblock_inst_user_wrapper_0] \
    -filter {SITE_TYPE !~ SLICE* && SITE_TYPE !~ DSP* && SITE_TYPE !~ RAMB* && \
      SITE_TYPE !~ URAM* && SITE_TYPE != LAGUNA && SITE_TYPE != HARD_SYNC}]
set_property SNAPPING_MODE ON [get_pblocks pblock_inst_user_wrapper_0]
set_property IS_SOFT FALSE [get_pblocks pblock_inst_user_wrapper_0]
