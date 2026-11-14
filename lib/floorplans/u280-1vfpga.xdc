# One reconfigurable vFPGA region for U280 shells, taken from QShell
# (TUM-DSE/QShell b62d14e, hw/floorplans/qshell_u280.xdc). The ranges
# complement Coyote's locked U280 static/shell floorplan and keep the shell's
# placeholder app and later BUILD_APP implementations in the same region.

create_pblock pblock_inst_user_wrapper_0
add_cells_to_pblock [get_pblocks pblock_inst_user_wrapper_0] [get_cells -quiet [list inst_shell/inst_dynamic/inst_user_wrapper_0]]
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add {SLICE_X0Y660:SLICE_X116Y719}
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add {DSP48E2_X0Y258:DSP48E2_X15Y281}
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add {RAMB18_X0Y264:RAMB18_X7Y287}
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add {RAMB36_X0Y132:RAMB36_X7Y143}
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add {URAM288_X0Y176:URAM288_X1Y191}
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -add {CLOCKREGION_X0Y7:CLOCKREGION_X5Y10 CLOCKREGION_X0Y0:CLOCKREGION_X3Y6}
# The clock regions above contain hard blocks the shell uses: the QSFP0
# transceivers of the CMAC (GTYE4 X0Y40-43) and the HBM controller ports (BLI
# HBM APB/AXI X0-X15). Leave them to the shell, or DFX validation rejects the
# app link (HDPR-6/19) and placement of the HBM fails.
resize_pblock [get_pblocks pblock_inst_user_wrapper_0] -remove [get_sites -filter {SITE_TYPE =~ GTYE4_* || SITE_TYPE =~ BLI_HBM_* || SITE_TYPE =~ HBM_REF_CLK*}]
set_property SNAPPING_MODE ON [get_pblocks pblock_inst_user_wrapper_0]
set_property IS_SOFT FALSE [get_pblocks pblock_inst_user_wrapper_0]
