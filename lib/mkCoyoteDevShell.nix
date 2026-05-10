{
  pkgs,
  tools,
  coyoteRoot,
  packages ? [ ],
  shellHook ? "",
  withXilinx ? false,
  coyotePlatform ? null,
  fdevName ? null,
  targetPlatform ? null,
  xilinxVersion ? null,
  fpgaPartHint ? null,
  fpgaPackage ? null,
  fpgaArtifact ? null,
  driverPackage ? null,
  sim ? { },
}:
let
  basePackages =
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
      clang-tools
      asm-lsp
      bash-language-server
      nixfmt-rfc-style
      verible
    ])
    ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
      pkgs.numactl
      pkgs.pciutils
      pkgs.kmod
      pkgs.procps
    ];

  shellHookCommon = builtins.replaceStrings [ "@COYOTE_ROOT@" ] [ (toString coyoteRoot) ] (
    builtins.readFile ../nix/tools/shellhook-common.sh
  );

  shellHookXilinx =
    builtins.replaceStrings [ "@XILINX_WRAPPER_LIB@" ] [ "${tools.xilinxWrapperLib}" ]
      (builtins.readFile ../nix/tools/shellhook-xilinx.sh);

  maybeExport =
    name: value:
    pkgs.lib.optionalString (value != null) ''
      export ${name}=${pkgs.lib.escapeShellArg (toString value)}
    '';

  hasSim = sim != { };
  simWorkspaceSuffix =
    if sim ? workspaceSuffix then
      sim.workspaceSuffix
    else if fdevName != null then
      fdevName
    else
      "default";
  simProjectName = if sim ? projectName then sim.projectName else "project.xpr";
  simSimset = if sim ? simset then sim.simset else "sim_1";
  simMode = if sim ? mode then sim.mode else "behavioral";

  platformHook = ''
    ${maybeExport "COYOTE_NIX_PLATFORM" coyotePlatform}
    ${maybeExport "FDEV_NAME" fdevName}
    ${maybeExport "TARGET_PLATFORM" targetPlatform}
    ${maybeExport "COYOTE_NIX_XILINX_VERSION" xilinxVersion}
    ${maybeExport "FPGA_PART_HINT" fpgaPartHint}
    ${maybeExport "FPGA_PACKAGE" fpgaPackage}
    ${maybeExport "COYOTE_DRIVER_PACKAGE" driverPackage}

    coyote_nix_project_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    export COYOTE_NIX_BUILD_ROOT="''${COYOTE_NIX_BUILD_ROOT:-$coyote_nix_project_root/.build}"
  ''
  + pkgs.lib.optionalString (fpgaPackage != null) ''
    case "''${COYOTE_NIX_PLATFORM:-''${FDEV_NAME:-}}" in
      v80|*v80*|versal|*versal*) export COYOTE_NIX_VERSAL_FPGA_PACKAGE="''${COYOTE_NIX_VERSAL_FPGA_PACKAGE:-${fpgaPackage}}" ;;
      u280|*u280*|ultrascale|*ultrascale*) export COYOTE_NIX_ULTRASCALE_FPGA_PACKAGE="''${COYOTE_NIX_ULTRASCALE_FPGA_PACKAGE:-${fpgaPackage}}" ;;
    esac
  ''
  + pkgs.lib.optionalString (fpgaArtifact != null) ''
    case "''${COYOTE_NIX_PLATFORM:-''${FDEV_NAME:-}}" in
      v80|*v80*|versal|*versal*) export COYOTE_NIX_VERSAL_FPGA_ARTIFACT="''${COYOTE_NIX_VERSAL_FPGA_ARTIFACT:-${fpgaArtifact}}" ;;
      u280|*u280*|ultrascale|*ultrascale*) export COYOTE_NIX_ULTRASCALE_FPGA_ARTIFACT="''${COYOTE_NIX_ULTRASCALE_FPGA_ARTIFACT:-${fpgaArtifact}}" ;;
    esac
  ''
  + pkgs.lib.optionalString hasSim ''
    export XDB_SIM_WORKSPACE="''${XDB_SIM_WORKSPACE:-''${COYOTE_NIX_BUILD_ROOT}/sim-workspace-${simWorkspaceSuffix}}"
    ${maybeExport "XDB_SIM_PACKAGE_PROJECT" (if sim ? packageProject then sim.packageProject else null)}
    ${maybeExport "XDB_SIM_PACKAGE_RUNTIME" (if sim ? packageRuntime then sim.packageRuntime else null)}
    export XDB_SIM_PROJECT="''${XDB_SIM_PROJECT:-''${XDB_SIM_WORKSPACE}/sim/${simProjectName}}"
    export XDB_SIM_SIMSET="''${XDB_SIM_SIMSET:-${simSimset}}"
    ${maybeExport "XDB_SIM_TOP" (if sim ? top then sim.top else null)}
    export XDB_SIM_MODE="''${XDB_SIM_MODE:-${simMode}}"
    ${maybeExport "XDB_SIM_SESSION" (if sim ? session then sim.session else null)}
  '';
in
pkgs.mkShell {
  packages = basePackages ++ packages ++ pkgs.lib.optionals withXilinx tools.all;
  shellHook =
    pkgs.lib.optionalString withXilinx (shellHookXilinx + "\n")
    + platformHook
    + "\n"
    + shellHookCommon
    + "\n"
    + shellHook;
}
