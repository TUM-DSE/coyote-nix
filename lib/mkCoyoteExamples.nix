# Build Coyote's examples for every board a site provides.
#
# Returns <board>.<example>, for example u280.hello_world. Each example is a
# derivation with the host program in bin/ and, for examples with hardware,
# the final hardware stage in hw/. Its passthru has sw, hw and the hardware
# stages (synth, routed, ...), so `.hw` builds only the bitstream and `.sw`
# only the host program.
{
  pkgs,
  # From coyote-nix's mkTools for coyoteRoot and the site's Xilinx root.
  tools,
  coyoteRoot,
  # The site's Xilinx facts, in the shape of doctor-cluster-xilinx's
  # mkXilinxContext:
  #   xilinxShareRoot               Xilinx installation root
  #   xilinxShell (optional)        FHS shell the Xilinx tools run in
  #   boards.<board>.xilinxVersion  Vivado version per board
  # Boards without a coyote-nix profile, such as Intel boards, are skipped.
  site,
  # Restrict to these example names; null builds all of them.
  examples ? null,
  amdGpuTargets ? [ "gfx90a" ],
  version ? "0.1.0",
}:
let
  inherit (pkgs) lib;

  boardProfiles = import ./coyoteBoardProfiles.nix;
  allExamples = import ./coyoteExamples.nix;

  fail = message: throw "coyote-nix: mkCoyoteExamples: ${message}";

  checkedSite =
    if !builtins.isAttrs site then
      fail "site must be an attribute set"
    else if !(site ? xilinxShareRoot) then
      fail "site.xilinxShareRoot is missing"
    else if !(site ? boards) || !builtins.isAttrs site.boards then
      fail "site.boards must be an attribute set of boards"
    else
      site;

  siteBoards = lib.filterAttrs (name: _: boardProfiles ? ${name}) checkedSite.boards;
  checkedSiteBoards = lib.mapAttrs (
    name: board:
    if !(board ? xilinxVersion) then
      fail "site.boards.${name}.xilinxVersion is missing"
    else
      board
  ) siteBoards;

  knownExamples = lib.concatStringsSep ", " (lib.attrNames allExamples);
  selectedExamples =
    if examples == null then
      allExamples
    else
      lib.genAttrs examples (
        name:
        allExamples.${name}
          or (fail "unknown example ${name}; known: ${knownExamples}")
      );

  # The project name from the example's hardware CMakeLists.txt.
  projectNameOf =
    example:
    let
      path = "examples/${example.directory}/hw/CMakeLists.txt";
      cmakeLists = builtins.readFile "${coyoteRoot}/${path}";
      found = builtins.match ".*\nproject\(([A-Za-z0-9_]+)\).*" cmakeLists;
    in
    if found == null then fail "no project() in ${path}" else lib.head found;

  # Software does not depend on the board, so all boards share it.
  software = lib.mapAttrs (
    name: example:
    import ./mkCoyoteExampleSoftware.nix {
      inherit
        pkgs
        coyoteRoot
        name
        version
        amdGpuTargets
        ;
      inherit (example) directory;
      gpu = example.gpu or false;
      postPatch = example.swPostPatch or "";
    }
  ) selectedExamples;

  # Coyote's CMake finds itself at ../../.. from the hardware directory. A
  # patched example therefore needs a tree in which the rest of Coyote sits
  # at that position, which symlinks provide.
  mkHwSource =
    {
      name,
      example,
      board,
    }:
    let
      patch = example.hwPatch.${board} or null;
      relative = "examples/${example.directory}/hw";
    in
    if patch == null then
      "${coyoteRoot}/${relative}"
    else
      let
        tree = pkgs.runCommand "coyote-example-${name}-${board}-source" { } ''
          mkdir -p "$out/examples/${example.directory}"
          for entry in ${coyoteRoot}/* ${coyoteRoot}/.[!.]*; do
            [ -e "$entry" ] || continue
            [ "$(basename "$entry")" = examples ] && continue
            ln -s "$entry" "$out/$(basename "$entry")"
          done
          cp -r ${coyoteRoot}/${relative} "$out/${relative}"
          chmod -R u+w "$out/${relative}"
          cd "$out/${relative}"
          ${patch}
        '';
      in
      "${tree}/${relative}";

  # Coyote's comp_spinal.tcl runs `sbt --warn "runMain <Kernel>Verilog"` and
  # takes gen/*.v. This sbt hands over the pre-generated Verilog instead.
  mkSpinalTools =
    example:
    let
      verilog = lib.mapAttrs (
        kernel: hash:
        import ./mkCoyoteSpinalVerilog.nix {
          inherit
            pkgs
            coyoteRoot
            kernel
            hash
            ;
          kernelSource = "${coyoteRoot}/examples/${example.directory}/hw/src/spinal/${kernel}";
        }
      ) example.spinalKernels;
      cases = lib.concatStrings (
        lib.mapAttrsToList (kernel: drv: ''
          ${kernel}) source=${drv} ;;
        '') verilog
      );
    in
    [
      pkgs.jdk17_headless
      (pkgs.writeShellScriptBin "sbt" ''
        set -euo pipefail
        main=""
        for arg in "$@"; do
          case "$arg" in
            "runMain "*) main=''${arg#runMain } ;;
          esac
        done
        case "''${main%Verilog}" in
        ${cases}
          *)
            echo "coyote-nix: no pre-generated Verilog for SpinalHDL main '$main'" >&2
            exit 1
            ;;
        esac
        mkdir -p gen
        cp "$source"/*.v gen/
        chmod u+w gen/*.v
      '')
    ];

  mkExample =
    board: name: example:
    let
      sw = software.${name};
      boardPackages = import ./mkCoyoteBoardPackages.nix {
        inherit pkgs tools coyoteRoot;
        inherit (checkedSite) xilinxShareRoot;
        xilinxShell = checkedSite.xilinxShell or null;
        hwSource = mkHwSource { inherit name example board; };
        nativeBuildInputs = lib.optionals (example ? spinalKernels) (mkSpinalTools example);
        pnamePrefix = "coyote-example-${name}";
        projectName = projectNameOf example;
        inherit version;
        boards.${board} = {
          inherit (checkedSiteBoards.${board}) xilinxVersion;
        }
        // lib.optionalAttrs (checkedSiteBoards.${board} ? simXilinxVersion) {
          inherit (checkedSiteBoards.${board}) simXilinxVersion;
        };
      };
      prefix = "coyote-example-${name}-${board}";
      stages = lib.mapAttrs' (
        pname:
        lib.nameValuePair (
          if pname == prefix then "final" else lib.removePrefix "${prefix}-" pname
        )
      ) boardPackages;
      hw = stages.final;
    in
    pkgs.runCommand "coyote-example-${name}-${board}"
      {
        passthru = {
          inherit sw hw stages;
        };
        meta = {
          description = "Coyote example ${example.directory} for ${board}";
          mainProgram = name;
        };
      }
      ''
        mkdir -p "$out"
        ln -s ${sw}/bin "$out/bin"
        ln -s ${hw} "$out/hw"
      '';

  mkSoftwareOnlyExample =
    board: name: example:
    let
      sw = software.${name};
    in
    pkgs.runCommand "coyote-example-${name}-${board}"
      {
        passthru = {
          inherit sw;
        };
        meta = {
          description = "Coyote example ${example.directory} (host program only)";
          mainProgram = name;
        };
      }
      ''
        mkdir -p "$out"
        ln -s ${sw}/bin "$out/bin"
      '';
in
lib.mapAttrs (
  board: siteBoard:
  builtins.seq siteBoard lib.mapAttrs (
    name: example:
    if example.hardware or true then
      mkExample board name example
    else
      mkSoftwareOnlyExample board name example
  ) (
    lib.filterAttrs (
      _: example: !(example.hardware or true) || builtins.elem board example.boards
    ) selectedExamples
  )
) checkedSiteBoards
