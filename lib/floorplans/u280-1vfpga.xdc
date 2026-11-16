# One reconfigurable vFPGA region for U280 shells. Ten clock regions at the
# bottom of the middle SLR give about 130K LUTs and 108 RAMB36, above the
# largest example, and sit next to the static region's host interface. The
# shell keeps the bottom SLR for the HBM ports it drives and one unbroken band
# from the top of the middle SLR into the top SLR for the network stack. A
# region reaching higher split the RDMA stack around it, and the original
# region covered the HBM ports; both missed timing by more than 1 ns.

create_pblock pblock_inst_user_wrapper_0
add_cells_to_pblock [get_pblocks pblock_inst_user_wrapper_0] [get_cells -quiet [list inst_shell/inst_dynamic/inst_user_wrapper_0]]
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add {CLOCKREGION_X1Y4:CLOCKREGION_X5Y5}
# Applications need only fabric, so hard blocks and I/O in these clock regions
# stay with the shell; otherwise DFX validation rejects the app link.
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -remove \
  [get_sites -of [get_pblocks pblock_inst_user_wrapper_0] \
    -filter {SITE_TYPE !~ SLICE* && SITE_TYPE !~ DSP* && SITE_TYPE !~ RAMB* && \
      SITE_TYPE !~ URAM* && SITE_TYPE != LAGUNA && SITE_TYPE != HARD_SYNC}]
set_property SNAPPING_MODE ON [get_pblocks pblock_inst_user_wrapper_0]
set_property IS_SOFT FALSE [get_pblocks pblock_inst_user_wrapper_0]
