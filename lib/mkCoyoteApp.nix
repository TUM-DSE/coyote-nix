# Build an application for a shell from mkCoyoteShell: only its vFPGA
# partial bitstreams, linked against the shell's locked checkpoint.
#
# The application takes all shell settings from the shell. Coyote imports
# them from the shell's export.cmake, overriding what the application's
# CMakeLists.txt sets.
{
  shell,
  name,
  # A Coyote hardware project: CMakeLists.txt calling load_apps() and
  # create_hw(), and the vfpga_top.svh sources it loads.
  src,
  # Tools for the application's own generators.
  nativeBuildInputs ? [ ],
  # Whether the application contains HLS kernels.
  requiresVitisHls ? true,
  cmakeFlags ? [ ],
  version ? "0.1.0",
}:
let
  info = shell.coyoteShell or (throw "coyote-nix: mkCoyoteApp: shell must come from mkCoyoteShell");
  inherit (info) site;

  app = import ./mkCoyoteAppPackage.nix {
    inherit (info) pkgs tools coyoteRoot;
    inherit
      requiresVitisHls
      cmakeFlags
      nativeBuildInputs
      version
      ;
    inherit (site) xilinxShareRoot;
    xilinxShell = site.xilinxShell or null;
    hwSource = src;
    pname = "coyote-app-${info.board}-${name}";
    shellPackage = shell;
    board = info.board;
    provenance = {
      application = name;
      shell = info.name;
    };
  };
in
app
// {
  inherit shell;
  coyoteApp = {
    api = "coyote-nix.app/v1";
    inherit name;
    inherit (info) board;
  };
}
