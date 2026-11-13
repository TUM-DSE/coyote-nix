# Build a Coyote shell, the static layer plus the dynamic layer with a chosen
# set of services, for applications built with mkCoyoteApp.
#
# The shell's vFPGA regions hold a generated placeholder app, so the build
# depends only on the board, the services, the Coyote source and the site:
# equal requests give the same derivation. After linking, the placeholder is
# replaced by a grey box, so every interface the shell offers gets a
# partition pin. The result is the shell from mkCoyoteShellPackage. Its
# bitstream is a full image (static, shell and an inert app region whose
# outputs are 0), and passthru.coyoteShell describes it.
{
  pkgs,
  # From coyote-nix's mkTools for coyoteRoot and the site's Xilinx root.
  tools,
  coyoteRoot,
  # The site's Xilinx facts, in the shape of doctor-cluster-xilinx's
  # mkXilinxContext: xilinxShareRoot, xilinxShell (optional) and
  # boards.<board>.xilinxVersion.
  site,
  board,
  # See coyoteShellServices.nix for names and defaults.
  services ? { },
  # "prebuilt" uses the static layer that ships with Coyote. "source" builds
  # it with the site's Vivado (U280 only).
  static ? "prebuilt",
  # vFPGA floorplan (FPLAN_PATH). null selects coyote-nix's default.
  floorplan ? null,
  # Coyote's BUILD_OPT: slower, more thorough place and route.
  optimize ? false,
  # Fail the build when validation (routing, DRC, timing) fails. Otherwise the
  # bitstream is built anyway and metadata/validation.json has the result.
  strict ? false,
  # Further Coyote settings, for example clocks. Service settings belong in
  # services.
  cmakeFlags ? [ ],
  version ? "0.1.0",
}:
let
  inherit (pkgs) lib;

  fail = message: throw "coyote-nix: mkCoyoteShell: ${message}";
  serviceLib = import ./coyoteShellServices.nix { inherit lib; };
  boardProfiles = import ./coyoteBoardProfiles.nix;

  supportedBoards = lib.concatStringsSep ", " (lib.attrNames boardProfiles);
  checkedBoard =
    if !(boardProfiles ? ${board}) then
      fail "unsupported board ${board}; supported: ${supportedBoards}"
    else if !(site.boards or { }) ? ${board} then
      fail "the site has no board ${board}"
    else if !(site.boards.${board} ? xilinxVersion) then
      fail "site.boards.${board}.xilinxVersion is missing"
    else if !(site ? xilinxShareRoot) then
      fail "site.xilinxShareRoot is missing"
    else
      board;

  requested = serviceLib.normalize checkedBoard services;
  # Coyote generates its network stack with Vitis HLS.
  networking = requested.rdma || requested.tcp || requested.sniffer;
  # coyote-nix's staged implementation builds one configuration with one
  # vFPGA. Coyote would build the others too, but nothing would implement
  # them, so a larger shell would lack their bitstreams.
  normalized =
    if requested.vfpgas != 1 || requested.configurations != 1 then
      fail (
        "shells with several vFPGAs or configurations are not supported yet; "
        + "requested ${toString requested.vfpgas} vFPGAs and "
        + "${toString requested.configurations} configurations"
      )
    else
      requested;

  serviceFlagNames = lib.attrNames (serviceLib.settings normalized);
  reservedFlag =
    flag:
    builtins.any (name: lib.hasPrefix "-D${name}=" flag || lib.hasPrefix "-D${name}:" flag) (
      serviceFlagNames
      ++ [
        "BUILD_OPT"
        "FPLAN_PATH"
        "SNIFFER_VFPGA_ID"
      ]
    );
  checkedCmakeFlags =
    let
      reserved = builtins.filter reservedFlag cmakeFlags;
    in
    if reserved != [ ] then
      fail "set ${lib.concatStringsSep " " reserved} through services, optimize or floorplan"
    else
      cmakeFlags;

  defaultFloorplans = {
    u280 = ./floorplans/u280-1vfpga.xdc;
    v80 = "${coyoteRoot}/examples/10_app_reconfiguration/hw/floorplans/example_fplan_v80.xdc";
  };
  requestedFloorplan = if floorplan != null then floorplan else defaultFloorplans.${checkedBoard};
  # Interpolating a path copies it to the store, so the build can read it.
  effectiveFloorplan =
    let
      p = requestedFloorplan;
    in
    if builtins.isPath p then "${p}" else toString p;

  # The generated shell project: the services come from cache settings, and
  # every region of every configuration loads the placeholder app.
  regionDirectory = region: "placeholder/region_${toString region}";
  mkShellSource =
    s:
    let
      regions = lib.range 0 (s.vfpgas - 1);
      loadLine = c: r: ''VFPGA_C${toString c}_${toString r} "${regionDirectory r}"'';
      loadApps = lib.concatStringsSep "\n" (
        lib.concatMap (config: map (loadLine config) regions) (lib.range 0 (s.configurations - 1))
      );
      cmakeLists = pkgs.writeText "CMakeLists.txt" ''
        cmake_minimum_required(VERSION 3.15)
        set(CYT_DIR "$ENV{COYOTE_ROOT}")
        list(APPEND CMAKE_MODULE_PATH "''${CYT_DIR}/cmake")
        find_package(CoyoteHW REQUIRED)
        project(coyote_shell)
        validation_checks_hw()
        load_apps(
        ${loadApps}
        )
        create_hw()
      '';
      placeholder = region: pkgs.writeText "vfpga_top.svh" (serviceLib.placeholderApp s region);
    in
    pkgs.runCommand "coyote-shell-${checkedBoard}-${serviceLib.name s}-source" { } (
      ''
        mkdir -p "$out"
        cp ${cmakeLists} "$out/CMakeLists.txt"
      ''
      + lib.concatMapStrings (region: ''
        mkdir -p "$out/${regionDirectory region}"
        cp ${placeholder region} "$out/${regionDirectory region}/vfpga_top.svh"
      '') regions
    );
  hwSource = mkShellSource normalized;

  settingsFlags =
    serviceLib.cmakeFlags normalized
    ++ [
      "-DBUILD_OPT:STRING=${if optimize then "1" else "0"}"
      "-DFPLAN_PATH:STRING=${effectiveFloorplan}"
    ]
    ++ lib.optional normalized.sniffer "-DSNIFFER_VFPGA_ID:STRING=0";

  xilinxVersion = site.boards.${checkedBoard}.xilinxVersion;
  xilinxShell = site.xilinxShell or null;

  # The static layer built from source, through the board flow on the same
  # generated project. Its static stages do not depend on the services.
  sourceStatic =
    let
      prefix = "coyote-static";
      packages = import ./mkCoyoteBoardPackages.nix {
        inherit
          pkgs
          tools
          coyoteRoot
          version
          xilinxShell
          ;
        inherit (site) xilinxShareRoot;
        hwSource = staticHwSource;
        requiresVitisHls = networking;
        inherit strict;
        pnamePrefix = prefix;
        boards.${checkedBoard} = {
          inherit xilinxVersion;
          staticCmakeFlags = serviceLib.cmakeFlags (serviceLib.normalize checkedBoard { });
        };
      };
    in
    packages."${prefix}-${checkedBoard}-static";
  # The static build gets the default services, so it is the same for every
  # shell on a board.
  staticHwSource = mkShellSource (serviceLib.normalize checkedBoard { });

  staticPath =
    if static == "prebuilt" then
      "${coyoteRoot}/hw/checkpoints"
    else if static == "source" then
      if checkedBoard == "u280" then
        "${sourceStatic}/checkpoints"
      else
        fail "static = \"source\" is supported only on the U280; the V80 uses Coyote's static layer"
    else
      fail "static must be \"prebuilt\" or \"source\"";

  # Non-default choices change the shell, so they appear in its name.
  customized = floorplan != null || cmakeFlags != [ ] || static != "prebuilt";
  identity = builtins.hashString "sha256" (
    builtins.toJSON {
      floorplan = builtins.unsafeDiscardStringContext effectiveFloorplan;
      inherit cmakeFlags static;
    }
  );
  name =
    serviceLib.name normalized
    + lib.optionalString optimize "-opt"
    + lib.optionalString customized "-${builtins.substring 0 8 identity}";

  shell = import ./mkCoyoteShellPackage.nix {
    inherit
      pkgs
      tools
      coyoteRoot
      hwSource
      xilinxShell
      xilinxVersion
      staticPath
      version
      ;
    inherit (site) xilinxShareRoot;
    board = checkedBoard;
    requiresVitisHls = networking;
    inherit strict;
    greyboxApplications = true;
    pname = "coyote-shell-${checkedBoard}-${name}";
    cmakeFlags = settingsFlags ++ checkedCmakeFlags;
    provenance = {
      shellServices = normalized;
      seedApplication = "coyote-nix-placeholder";
    };
  };
in
shell
// {
  inherit hwSource;
  coyoteShell = {
    api = "coyote-nix.shell/v1";
    inherit
      pkgs
      tools
      coyoteRoot
      site
      name
      static
      optimize
      ;
    board = checkedBoard;
    services = normalized;
    floorplan = effectiveFloorplan;
    settings = serviceLib.settings normalized;
  };
}
