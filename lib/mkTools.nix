{
  pkgs,
  coyoteRoot,
  xilinxShareRoot,
  # The fpga-nix library. The coyote-nix flake supplies it; direct importers of
  # ./lib must pass it themselves.
  fpgaNixLib ? throw "coyote-nix: mkTools requires fpgaNixLib (fpga-nix.lib)",
  platforms ? pkgs.lib.platforms.linux,
  extraRuntimeInputs ? [ ],
  fpgahogPackage ? null,
}:
let
  common = ../nix/tools/coyote-common.sh;

  # Vendor tool wrappers and host tools come from fpga-nix.
  xilinx = fpgaNixLib.mkXilinxTools { inherit pkgs xilinxShareRoot platforms; };
  host = fpgaNixLib.mkHostTools { inherit pkgs platforms; };

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

in
rec {
  inherit mkTool;
  inherit (xilinx) wrapperLib;
  # Older name of wrapperLib.
  xilinxWrapperLib = xilinx.wrapperLib;

  checkXilinxEnv = mkTool {
    name = "check-xilinx-env";
    description = "Print environment and FPGA checks (Vivado, hugepages, PCI devices).";
    body = builtins.readFile ../nix/tools/check-xilinx-env.sh;
  };

  program-cli = mkTool {
    name = "program-cli";
    description = "Program an explicit FPGA image via Vivado batch.";
    runtimeInputs = [ xilinx.program-fpga ];
    body = builtins.readFile ../nix/tools/program-cli.sh;
  };

  deploy-hw = mkTool {
    name = "deploy-hw";
    description = "Unload driver, program hardware, reset, set hugepages, and insert driver.";
    runtimeInputs = [ pkgs.util-linux ] ++ pkgs.lib.optional (fpgahogPackage != null) fpgahogPackage;
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

  inherit (host) hot-reset set-hugepages;

  insert-driver = mkTool {
    name = "insert-driver";
    description = "Insert Coyote driver with optional network args: insert-driver [ko_path] [image_hint].";
    body = builtins.readFile ../nix/tools/insert-driver.sh;
  };

  gen-verible-filelist = mkTool {
    name = "gen-verible-filelist";
    description = "Generate verible.filelist from tracked HDL sources.";
    body = builtins.readFile ../nix/tools/gen-verible-filelist.sh;
  };

  inherit (xilinx) vivado hw_server vitis_hls;

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

  # fpga-nix ships Bootgen, XSDB and the Arm R5 toolchain as one package.
  armr5 = xilinx.embedded;
  bootgen = xilinx.embedded;
  xsdb = xilinx.embedded;
  embedded = xilinx.embedded;

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
