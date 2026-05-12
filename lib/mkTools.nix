{
  pkgs,
  coyoteRoot,
  xilinxShareRoot,
  platforms ? pkgs.lib.platforms.linux,
  extraRuntimeInputs ? [ ],
}:
let
  common = ../nix/tools/coyote-common.sh;
  xilinxWrapperLib = pkgs.writeText "xilinx-wrapper-lib.sh" (
    builtins.replaceStrings
      [ "@NCURSES6_LIB@" "@XILINX_SHARE_ROOT@" ]
      [ "${pkgs.ncurses6}/lib/libtinfo.so.6" (toString xilinxShareRoot) ]
      (builtins.readFile ../nix/tools/xilinx-wrapper-lib.sh)
  );

  coyoteRootValue = toString coyoteRoot;

  mkTool =
    {
      name,
      description,
      body,
      runtimeInputs ? [ ],
    }:
    pkgs.writeShellApplication {
      inherit name;
      inheritPath = true;
      runtimeInputs =
        (with pkgs; [
          bash
          coreutils
          findutils
          gnugrep
          gawk
          gnused
          git
          cmake
          gnumake
          gcc
          pkg-config
          boost
          which
          nix
        ])
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          pkgs.numactl
          pkgs.pciutils
          pkgs.kmod
          pkgs.procps
        ]
        ++ runtimeInputs
        ++ extraRuntimeInputs;
      text = ''
        # shellcheck source=/dev/null
        source ${common}
        if [ -z "''${COYOTE_ROOT:-}" ]; then
          export COYOTE_ROOT="${coyoteRootValue}"
        fi
        if [ -z "''${COYOTE_NIX_NCURSES6_LIB:-}" ]; then
          export COYOTE_NIX_NCURSES6_LIB="${pkgs.ncurses6}/lib/libtinfo.so.6"
        fi
        ${body}
      '';
      meta = {
        description = description;
        mainProgram = name;
        platforms = platforms;
      };
    };

  mkXilinxWrapper =
    {
      name,
      description,
      script,
    }:
    pkgs.writeShellApplication {
      inherit name;
      inheritPath = true;
      runtimeInputs = with pkgs; [
        bash
        coreutils
        gawk
        gnumake
        inetutils
      ];
      text = builtins.replaceStrings [ "@XILINX_WRAPPER_LIB@" ] [ "${xilinxWrapperLib}" ] (
        builtins.readFile script
      );
      meta = {
        description = description;
        mainProgram = name;
        platforms = platforms;
      };
    };
in
rec {
  inherit xilinxWrapperLib mkTool mkXilinxWrapper;

  checkXilinxEnv = mkTool {
    name = "check-xilinx-env";
    description = "Print environment and FPGA checks (Vivado, hugepages, PCI devices).";
    body = builtins.readFile ../nix/tools/check-xilinx-env.sh;
  };

  program-cli = mkTool {
    name = "program-cli";
    description = "Program FPGA via Vivado batch. Defaults can be supplied by the consuming project.";
    runtimeInputs = [ pkgs.util-linux ];
    body = builtins.readFile ../nix/tools/program-cli.sh;
  };

  deploy-hw = mkTool {
    name = "deploy-hw";
    description = "Unload driver, program hardware, reset, set hugepages, and insert driver.";
    body = builtins.readFile ../nix/tools/deploy-hw.sh;
  };

  unload-driver = mkTool {
    name = "unload-driver";
    description = "Unload Coyote kernel driver if present.";
    body = builtins.readFile ../nix/tools/unload-driver.sh;
  };

  hot-reset = mkTool {
    name = "hot-reset";
    description = "Run a PCIe secondary-bus hot reset on the FPGA's upstream bridge: hot-reset [bdf].";
    body = builtins.readFile ../nix/tools/hot-reset.sh;
  };

  insert-driver = mkTool {
    name = "insert-driver";
    description = "Insert Coyote driver with optional network args: insert-driver [ko_path] [image_hint].";
    body = builtins.readFile ../nix/tools/insert-driver.sh;
  };

  set-hugepages = mkTool {
    name = "set-hugepages";
    description = "Set vm.nr_hugepages (default 1024): set-hugepages [count].";
    body = builtins.readFile ../nix/tools/set-hugepages.sh;
  };

  gen-verible-filelist = mkTool {
    name = "gen-verible-filelist";
    description = "Generate verible.filelist from tracked HDL sources.";
    body = builtins.readFile ../nix/tools/gen-verible-filelist.sh;
  };

  vivado =
    let
      vivado-wrapper = mkXilinxWrapper {
        name = "vivado";
        description = "Run Vivado inside xilinx-shell.";
        script = ../nix/tools/vivado-wrapper.sh;
      };
      mkVivadoCompanionWrapper =
        name:
        mkXilinxWrapper {
          inherit name;
          description = "Run ${name} inside xilinx-shell.";
          script = ../nix/tools/vivado-companion-wrapper.sh;
        };
    in
    pkgs.symlinkJoin {
      name = "vivado";
      paths = [
        vivado-wrapper
        (mkVivadoCompanionWrapper "xsc")
        (mkVivadoCompanionWrapper "xvlog")
        (mkVivadoCompanionWrapper "xelab")
        (mkVivadoCompanionWrapper "xsim")
      ];
      meta = {
        description = "Run Vivado and companion simulation tools inside xilinx-shell.";
        mainProgram = "vivado";
        platforms = platforms;
      };
    };

  hw_server = mkXilinxWrapper {
    name = "hw_server";
    description = "Run hw_server inside xilinx-shell.";
    script = ../nix/tools/hw_server-wrapper.sh;
  };

  vitis_hls = mkXilinxWrapper {
    name = "vitis_hls";
    description = "Run Vitis HLS inside xilinx-shell.";
    script = ../nix/tools/vitis_hls-wrapper.sh;
  };

  all = [
    checkXilinxEnv
    program-cli
    deploy-hw
    unload-driver
    hot-reset
    insert-driver
    set-hugepages
    gen-verible-filelist
    vivado
    hw_server
    vitis_hls
  ];
}
