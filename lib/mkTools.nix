{
  pkgs,
  coyoteRoot,
  coyoteRevision ? null,
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
  sourceRevision = import ./resolveCoyoteSourceRevision.nix {
    inherit coyoteRoot coyoteRevision;
  };
  sourceRevisionValue = if sourceRevision == null then "" else sourceRevision;

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
        export COYOTE_NIX_EXPECTED_COYOTE_REVISION=${pkgs.lib.escapeShellArg sourceRevisionValue}
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
      runtimeInputs =
        (with pkgs; [
          bash
          coreutils
          gawk
          gnumake
          inetutils
        ])
        ++ extraRuntimeInputs;
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
    description = "Program an explicit FPGA image via Vivado batch.";
    runtimeInputs = [ pkgs.util-linux ];
    body = builtins.readFile ../nix/tools/program-cli.sh;
  };

  deploy-hw = mkTool {
    name = "deploy-hw";
    description = "Unload driver, program hardware, reset, set hugepages, and insert driver.";
    body = builtins.readFile ../nix/tools/deploy-hw.sh;
  };

  reconfigure-app = pkgs.stdenv.mkDerivation {
    pname = "coyote-reconfigure-app";
    version = "0.1.0";
    dontUnpack = true;
    buildInputs = [ pkgs.boost ];
    buildPhase = ''
      runHook preBuild
      $CXX -std=c++20 -O2 -Wall -Wextra -Werror \
        -isystem ${coyoteRootValue}/sw/include \
        -c ${../nix/tools/reconfigure-app.cpp} -o reconfigure-app.o
      $CXX -std=c++20 -O2 -Wall -Wextra -Wno-error=sign-compare \
        -isystem ${coyoteRootValue}/sw/include \
        -c ${coyoteRootValue}/sw/src/cRcnfg.cpp -o cRcnfg.o
      $CXX reconfigure-app.o cRcnfg.o -pthread -lrt -o reconfigure-app
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 reconfigure-app "$out/bin/reconfigure-app"
      runHook postInstall
    '';
    meta = {
      description = "Load a Coyote application partial image through the active driver";
      mainProgram = "reconfigure-app";
      platforms = platforms;
    };
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
        (mkVivadoCompanionWrapper "xvhdl")
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

  r5-elf-check =
    let
      python = pkgs.python3.withPackages (packages: [ packages.pyelftools ]);
    in
    mkTool {
      name = "coyote-r5-elf-check";
      description = "Validate a freestanding Cortex-R5 ELF against a TCM platform contract.";
      runtimeInputs = [ python ];
      body = ''
        exec ${python}/bin/python ${../nix/tools/check-r5-elf.py} "$@"
      '';
    };

  r5-bif = mkTool {
    name = "coyote-r5-bif";
    description = "Render or validate the accepted Versal delayed-handoff R5 BIF policy.";
    runtimeInputs = [ pkgs.python3 ];
    body = ''
      exec python3 ${../nix/tools/versal-r5-bif.py} "$@"
    '';
  };

  armr5 =
    let
      names = [
        "armr5-none-eabi-addr2line"
        "armr5-none-eabi-ar"
        "armr5-none-eabi-as"
        "armr5-none-eabi-c++filt"
        "armr5-none-eabi-gcc"
        "armr5-none-eabi-gcc-ar"
        "armr5-none-eabi-gcc-nm"
        "armr5-none-eabi-gcc-ranlib"
        "armr5-none-eabi-ld"
        "armr5-none-eabi-nm"
        "armr5-none-eabi-objcopy"
        "armr5-none-eabi-objdump"
        "armr5-none-eabi-ranlib"
        "armr5-none-eabi-readelf"
        "armr5-none-eabi-size"
        "armr5-none-eabi-strings"
        "armr5-none-eabi-strip"
      ];
      wrapper =
        name:
        mkXilinxWrapper {
          inherit name;
          description = "Run ${name} from the selected Vitis installation inside xilinx-shell.";
          script = ../nix/tools/xilinx-embedded-wrapper.sh;
        };
    in
    pkgs.symlinkJoin {
      name = "xilinx-armr5-tools";
      paths = map wrapper names;
      meta = {
        description = "Version-coherent Arm R5 compiler and binutils from Vitis";
        platforms = platforms;
      };
    };

  bootgen = mkXilinxWrapper {
    name = "bootgen";
    description = "Run Bootgen from the selected Vitis installation inside xilinx-shell.";
    script = ../nix/tools/xilinx-embedded-wrapper.sh;
  };

  embedded = pkgs.symlinkJoin {
    name = "xilinx-embedded-tools";
    paths = [
      armr5
      bootgen
    ];
    meta = {
      description = "Version-coherent Arm R5 and Bootgen tools from Vitis";
      platforms = platforms;
    };
  };

  all = [
    checkXilinxEnv
    program-cli
    deploy-hw
    reconfigure-app
    unload-driver
    hot-reset
    insert-driver
    set-hugepages
    gen-verible-filelist
    vivado
    hw_server
    vitis_hls
    r5-elf-check
    r5-bif
    embedded
  ];
}
