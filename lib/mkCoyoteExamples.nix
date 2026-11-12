# Build Coyote's examples for every board a site provides.
#
# Returns, per board:
#   <board>.<example>         bin/ (host program), app/ and shell/
#   <board>.<example>.sw      the host program
#   <board>.<example>.app     the application (vFPGA partial bitstreams)
#   <board>.<example>.shell   the shell it needs, from mkCoyoteShell
#   <board>.shells.<name>     every shell the examples need, built once
#
# Examples that share their services share one shell. An example marked
# monolithic is built in one piece instead and has .hw rather than .app and
# .shell. Examples without hardware have only bin/ and .sw.
{
  pkgs,
  # From coyote-nix's mkTools for coyoteRoot and the site's Xilinx root.
  tools,
  coyoteRoot,
  # The site's Xilinx facts, in the shape of doctor-cluster-xilinx's
  # mkXilinxContext: xilinxShareRoot, xilinxShell (optional) and
  # boards.<board>.xilinxVersion. Boards without a coyote-nix profile, such
  # as Intel boards, are skipped.
  site,
  # Restrict to these example names; null builds all of them.
  examples ? null,
  amdGpuTargets ? [ "gfx90a" ],
  # Fail hardware builds whose validation fails, instead of building
  # bitstreams that record the failure in metadata/validation.json.
  strict ? false,
  version ? "0.1.0",
}:
let
  inherit (pkgs) lib;

  boardProfiles = import ./coyoteBoardProfiles.nix;
  allExamples = import ./coyoteExamples.nix;
  serviceLib = import ./coyoteShellServices.nix { inherit lib; };

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
    if !(board ? xilinxVersion) then fail "site.boards.${name}.xilinxVersion is missing" else board
  ) siteBoards;

  knownExamples = lib.concatStringsSep ", " (lib.attrNames allExamples);
  selectedExamples =
    if examples == null then
      allExamples
    else
      lib.genAttrs examples (
        name: allExamples.${name} or (fail "unknown example ${name}; known: ${knownExamples}")
      );

  cmakeListsOf =
    example: builtins.readFile "${coyoteRoot}/examples/${example.directory}/hw/CMakeLists.txt";

  # The project name from the example's hardware CMakeLists.txt.
  projectNameOf =
    example:
    let
      found = builtins.match ".*\nproject\\(([A-Za-z0-9_]+)\\).*" (cmakeListsOf example);
    in
    if found == null then
      fail "no project() in ${example.directory}/hw/CMakeLists.txt"
    else
      lib.head found;

  # The settings an example's CMakeLists.txt assigns with set(NAME value).
  settingPattern = "[[:space:]]*set\\(([A-Z_0-9]+)[[:space:]]+\"?([^\" )]+)\"?\\).*";
  assignedSettings =
    example:
    lib.listToAttrs (
      lib.concatMap (
        line:
        let
          found = builtins.match settingPattern line;
        in
        lib.optional (found != null) (lib.nameValuePair (lib.elemAt found 0) (lib.elemAt found 1))
      ) (lib.splitString "\n" (cmakeListsOf example))
    );

  # Fail evaluation when an example's declared services no longer match the
  # settings in its CMakeLists.txt, for example after a Coyote update.
  checkServices =
    board: name: example:
    let
      normalized = serviceLib.normalize board example.services;
      expected = lib.mapAttrs (_: toString) (
        serviceLib.settings normalized
        // {
          BUILD_OPT = if example.optimize or false then 1 else 0;
        }
      );
      assigned = assignedSettings example;
      mismatches = lib.filter (
        setting: (assigned.${setting} or expected.${setting}) != expected.${setting}
      ) (lib.attrNames expected);
      describe = setting: "${setting} is ${assigned.${setting}}, not ${expected.${setting}}";
    in
    if mismatches == [ ] then
      normalized
    else
      fail "${name}: services do not match its CMakeLists.txt: ${
        lib.concatMapStringsSep "; " describe mismatches
      }";

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

  generatorTools = example: lib.optionals (example ? spinalKernels) (mkSpinalTools example);

  mkShellFor =
    board: services: optimize:
    import ./mkCoyoteShell.nix {
      inherit
        pkgs
        tools
        coyoteRoot
        board
        services
        optimize
        version
        strict
        ;
      site = checkedSite;
    };

  mkAppExample =
    board: name: example:
    let
      sw = software.${name};
      shell = mkShellFor board (checkServices board name example) (example.optimize or false);
      app = import ./mkCoyoteApp.nix {
        inherit
          shell
          name
          version
          strict
          ;
        src = mkHwSource { inherit name example board; };
        nativeBuildInputs = generatorTools example;
      };
    in
    pkgs.runCommand "coyote-example-${name}-${board}"
      {
        passthru = {
          inherit sw app shell;
        };
        meta = {
          description = "Coyote example ${example.directory} for ${board}";
          mainProgram = name;
        };
      }
      ''
        mkdir -p "$out"
        ln -s ${sw}/bin "$out/bin"
        ln -s ${app} "$out/app"
        ln -s ${shell} "$out/shell"
      '';

  mkMonolithicExample =
    board: name: example:
    let
      sw = software.${name};
      boardPackages = import ./mkCoyoteBoardPackages.nix {
        inherit pkgs tools coyoteRoot;
        inherit (checkedSite) xilinxShareRoot;
        xilinxShell = checkedSite.xilinxShell or null;
        hwSource = mkHwSource { inherit name example board; };
        nativeBuildInputs = generatorTools example;
        pnamePrefix = "coyote-example-${name}";
        projectName = projectNameOf example;
        inherit version strict;
        boards.${board} = {
          inherit (checkedSiteBoards.${board}) xilinxVersion;
        }
        // lib.optionalAttrs (checkedSiteBoards.${board} ? simXilinxVersion) {
          inherit (checkedSiteBoards.${board}) simXilinxVersion;
        };
      };
      prefix = "coyote-example-${name}-${board}";
      stageName = pname: if pname == prefix then "final" else lib.removePrefix "${prefix}-" pname;
      stages = lib.mapAttrs' (pname: lib.nameValuePair (stageName pname)) boardPackages;
      hw = stages.final;
      checked = checkServices board name example;
      drvName = "coyote-example-${name}-${board}";
    in
    builtins.seq checked pkgs.runCommand drvName
      {
        passthru = {
          inherit sw hw stages;
        };
        meta = {
          description = "Coyote example ${example.directory} for ${board}, built in one piece";
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

  mkExample =
    board: name: example:
    if !(example.hardware or true) then
      mkSoftwareOnlyExample board name example
    else if example.monolithic or false then
      mkMonolithicExample board name example
    else
      mkAppExample board name example;

  forBoard =
    board:
    let
      boardExamples = lib.mapAttrs (mkExample board) (
        lib.filterAttrs (
          _: example: !(example.hardware or true) || builtins.elem board example.boards
        ) selectedExamples
      );
      # Examples with equal services return the same shell; key by its name.
      shells = lib.listToAttrs (
        map (example: lib.nameValuePair example.shell.coyoteShell.name example.shell) (
          lib.filter (example: example ? shell) (lib.attrValues boardExamples)
        )
      );
    in
    if boardExamples ? shells then
      fail "an example must not be called shells"
    else
      boardExamples // { inherit shells; };
in
lib.mapAttrs (board: siteBoard: builtins.seq siteBoard (forBoard board)) checkedSiteBoards
