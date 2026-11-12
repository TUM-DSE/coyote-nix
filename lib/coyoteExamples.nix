# Coyote's examples (examples/<directory>) and what building them needs.
#
# boards lists the boards an example works on, following the support table in
# Coyote's examples/README.md, restricted to boards coyote-nix has profiles
# for. Examples without hardware run against other examples' bitstreams.
let
  bothBoards = [
    "u280"
    "v80"
  ];
in
{
  hello_world = {
    directory = "01_hello_world";
    boards = bothBoards;
  };
  hls_vadd = {
    directory = "02_hls_vadd";
    boards = bothBoards;
  };
  multitenancy = {
    directory = "03_multitenancy";
    boards = bothBoards;
  };
  user_interrupts = {
    directory = "04_user_interrupts";
    boards = bothBoards;
  };
  # Loads shell bitstreams built by other examples.
  reconfigure_shell = {
    directory = "05_reconfigure_shell";
    hardware = false;
  };
  # Moves data between the FPGA and an AMD Instinct GPU, with any shell.
  gpu_p2p = {
    directory = "06_gpu_p2p";
    hardware = false;
    gpu = true;
  };
  perf_fpga = {
    directory = "07_perf_fpga";
    boards = bothBoards;
  };
  multithreading = {
    directory = "08_multithreading";
    boards = bothBoards;
  };
  # Coyote does not support networking on the V80 yet.
  perf_rdma = {
    directory = "09_perf_rdma";
    boards = [ "u280" ];
  };
  # The example hardcodes the U55C and its floorplan. Coyote ships floorplans
  # only for the U55C and the V80, so switch it to the V80 settings, as the
  # example's README instructs.
  app_reconfiguration = {
    directory = "10_app_reconfiguration";
    boards = [ "v80" ];
    hwPatch.v80 = ''
      sed -i \
        -e 's|^set(FDEV_NAME "u55c")$|# &|' \
        -e 's|^set(FPLAN_PATH \(.*\)_u55c\.xdc")$|# &|' \
        -e 's|^# \(set(FDEV_NAME "v80")\)$|\1|' \
        -e 's|^# \(set(EN_SHELL_PBLOCK 0)\)$|\1|' \
        -e 's|^# \(set(FPLAN_PATH .*_v80\.xdc")\)$|\1|' \
        CMakeLists.txt
      grep -qx 'set(FDEV_NAME "v80")' CMakeLists.txt
      grep -qx 'set(EN_SHELL_PBLOCK 0)' CMakeLists.txt
      grep -q '^set(FPLAN_PATH .*_v80\.xdc")$' CMakeLists.txt
      ! grep -q '^set(FDEV_NAME "u55c")' CMakeLists.txt
    '';
  };
  packet_sniffer = {
    directory = "11_packet_sniffer";
    boards = [ "u280" ];
    # conversion.cpp uses uint64_t without including <cstdint>, which newer
    # GCC versions no longer pull in through other headers.
    swPostPatch = ''
      sed -i '1i #include <cstdint>' examples/11_packet_sniffer/sw/src/conversion.cpp
    '';
  };
  # Coyote compiles SpinalHDL kernels with sbt during the Vivado build, which
  # downloads dependencies. coyote-nix generates the Verilog beforehand in a
  # fixed-output derivation, so each kernel needs the hash of its Verilog.
  spinal_hdl = {
    directory = "12_spinal_hdl";
    boards = bothBoards;
    spinalKernels.VectorAdder = "sha256-jyllk3ZpWC2kcnp48VpgCT5LktQl98X5KKYRYVEjJ74=";
  };
}
