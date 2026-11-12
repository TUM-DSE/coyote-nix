{
  pkgs,
  tools,
  coyoteRoot,
  hwSource,
  xilinxShareRoot,
  xilinxShell ? null,
  requiresVitisHls ? true,
  pname,
  version ? "0.1.0",
  board,
  xilinxVersion,
  staticPath ? "${coyoteRoot}/hw/checkpoints",
  cmakeFlags ? [ ],
  provenance ? { },
  synthesisAnalysis ? { },
  timingOracle ? { },
  implementation ? { },
  # Fail the build when validation (routing, bitstream DRC, timing) fails.
  # Otherwise the bitstreams are built anyway and metadata/validation.json
  # records the result.
  strict ? false,
  subdivisionReference ? null,
  # Replace the seed application with a grey box (every port buffered by a
  # LUT) right after linking, so that Vivado places a partition pin for every
  # port the static region uses, not only for those the seed app happens to
  # use. Applications linked later can then use all of them.
  greyboxApplications ? false,
}:

let
  lib = pkgs.lib;
  boardProfiles = import ./coyoteBoardProfiles.nix;
  boardProfile =
    boardProfiles.${board}
      or (throw "coyote-nix: mkCoyoteShellPackage supports only u280 and v80, not ${board}");
  combineOptPlace = board == "u280" && xilinxVersion == "2023.2";
  collectPhysicalQorAssessment = !combineOptPlace;
  checkedSubdivisionReference =
    if subdivisionReference == null then null
    else if board != "u280" then
      throw "coyote-nix: subdivisionReference supports only u280"
    else if !(builtins.isAttrs subdivisionReference)
      || !(subdivisionReference ? checkpoint)
      || !(subdivisionReference ? staticCheckpoint)
      || !(subdivisionReference ? checkpointSha256)
      || !(subdivisionReference ? staticCheckpointSha256) then
      throw "coyote-nix: subdivisionReference requires checkpoint, staticCheckpoint and their Sha256 fields"
    else if !(builtins.all (hash: builtins.isString hash && builtins.match "[0-9a-f]{64}" hash != null)
      [ subdivisionReference.checkpointSha256 subdivisionReference.staticCheckpointSha256 ]) then
      throw "coyote-nix: subdivisionReference SHA256 values must be lowercase hexadecimal"
    else subdivisionReference;
  hasSubdivisionParent = boardProfile.fpgaArchitecture == "ultrascale_plus";
  subdivisionProvenance = lib.optionalAttrs (checkedSubdivisionReference != null) {
    subdivisionReference = {
      purpose = "pr_subdivide-only";
      checkpoint = toString checkedSubdivisionReference.checkpoint;
      staticCheckpoint = toString checkedSubdivisionReference.staticCheckpoint;
      inherit (checkedSubdivisionReference) checkpointSha256 staticCheckpointSha256;
    };
  };

  stageHelpers = import ./coyoteHwStageHelpers.nix {
    inherit
      pkgs
      tools
      coyoteRoot
      hwSource
      xilinxShareRoot
      xilinxShell
      version
      requiresVitisHls
      strict
      ;
  };

  inherit (stageHelpers)
    copyPreviousStageSetup
    finalBitgenCommand
    importStageFiles
    installCheckpointReports
    installValidationResult
    mkStage
    mkValidationResult
    writeArtifactManifest
    ;

  enShellPblock = if boardProfile.twoStage.enShellPblock then "1" else "0";
  isNumber = value: builtins.isInt value || builtins.isFloat value;
  synthesisAnalysisPolicy =
    let
      enable = synthesisAnalysis.enable or false;
      enforce = synthesisAnalysis.enforce or false;
      rejectSetupWnsBelow = synthesisAnalysis.rejectSetupWnsBelow or 0.0;
      passSetupWnsAtLeast = synthesisAnalysis.passSetupWnsAtLeast or 0.5;
      maximumLogicLevels = synthesisAnalysis.maximumLogicLevels or null;
      maxPaths = synthesisAnalysis.maxPaths or 100;
      maxFanoutNets = synthesisAnalysis.maxFanoutNets or 100;
    in
    if !builtins.isBool enable then
      throw "coyote-nix: synthesisAnalysis.enable must be a Boolean"
    else if !builtins.isBool enforce then
      throw "coyote-nix: synthesisAnalysis.enforce must be a Boolean"
    else if enforce && !enable then
      throw "coyote-nix: synthesisAnalysis.enforce requires synthesisAnalysis.enable"
    else if !isNumber rejectSetupWnsBelow then
      throw "coyote-nix: synthesisAnalysis.rejectSetupWnsBelow must be a number"
    else if !isNumber passSetupWnsAtLeast || passSetupWnsAtLeast < rejectSetupWnsBelow then
      throw "coyote-nix: synthesisAnalysis.passSetupWnsAtLeast must be a number at least as large as rejectSetupWnsBelow"
    else if
      maximumLogicLevels != null && (!builtins.isInt maximumLogicLevels || maximumLogicLevels < 1)
    then
      throw "coyote-nix: synthesisAnalysis.maximumLogicLevels must be null or a positive integer"
    else if !builtins.isInt maxPaths || maxPaths < 1 then
      throw "coyote-nix: synthesisAnalysis.maxPaths must be a positive integer"
    else if !builtins.isInt maxFanoutNets || maxFanoutNets < 1 then
      throw "coyote-nix: synthesisAnalysis.maxFanoutNets must be a positive integer"
    else
      {
        inherit
          enable
          enforce
          rejectSetupWnsBelow
          passSetupWnsAtLeast
          maximumLogicLevels
          maxPaths
          maxFanoutNets
          ;
      };
  timingOraclePolicy =
    let
      enforce = timingOracle.enforce or false;
      rejectRqaBelow = timingOracle.rejectRqaBelow or 3;
      passRqaAtLeast = timingOracle.passRqaAtLeast or 4;
      maxPaths = timingOracle.maxPaths or 100;
    in
    if !builtins.isBool enforce then
      throw "coyote-nix: timingOracle.enforce must be a Boolean"
    else if !builtins.isInt rejectRqaBelow || rejectRqaBelow < 1 || rejectRqaBelow > 5 then
      throw "coyote-nix: timingOracle.rejectRqaBelow must be an integer from 1 through 5"
    else if !builtins.isInt passRqaAtLeast || passRqaAtLeast < rejectRqaBelow || passRqaAtLeast > 5 then
      throw "coyote-nix: timingOracle.passRqaAtLeast must be an integer from rejectRqaBelow through 5"
    else if !builtins.isInt maxPaths || maxPaths < 1 then
      throw "coyote-nix: timingOracle.maxPaths must be a positive integer"
    else
      {
        inherit
          enforce
          rejectRqaBelow
          passRqaAtLeast
          maxPaths
          ;
      };
  shellBaseCmakeFlags = cmakeFlags ++ [
    "-DFDEV_NAME:STRING=${boardProfile.platform}"
    "-DBUILD_APP:STRING=0"
    "-DBUILD_STATIC:STRING=0"
    "-DBUILD_SHELL:STRING=1"
    "-DEN_PR:STRING=1"
    "-DEN_SHELL_PBLOCK:STRING=${enShellPblock}"
  ];
  shellSynthesisCmakeFlags = shellBaseCmakeFlags ++ [
    # Synthesis and its fast analysis do not read the routed/fixed static DCP.
    # Avoid making this stage wait for an unrelated static realization.
    "-DSTATIC_PATH=${coyoteRoot}/hw/checkpoints"
    "-DSYNTHESIS_ANALYSIS_MAX_PATHS:STRING=${toString synthesisAnalysisPolicy.maxPaths}"
    "-DSYNTHESIS_ANALYSIS_MAX_FANOUT_NETS:STRING=${toString synthesisAnalysisPolicy.maxFanoutNets}"
  ];
  shellCmakeFlags = shellBaseCmakeFlags ++ [
    "-DSTATIC_PATH=${toString staticPath}"
    "-DTIMING_ORACLE_REJECT_RQA_BELOW:STRING=${toString timingOraclePolicy.rejectRqaBelow}"
    "-DTIMING_ORACLE_PASS_RQA_AT_LEAST:STRING=${toString timingOraclePolicy.passRqaAtLeast}"
    "-DTIMING_ORACLE_MAX_PATHS:STRING=${toString timingOraclePolicy.maxPaths}"
  ];

  shellExpectedBitstreams = boardProfile.twoStage.shellExpectedBitstreams;
  shellImplementationBaseFlags = shellCmakeFlags ++ [
    "-DIMMUTABLE_IMPLEMENTATION_STAGES:BOOL=ON"
  ];
  effectiveFlagValue = name: flags:
    let matches = builtins.filter (entry: entry != null) (map (flag:
      builtins.match "^-D${name}(:[^=]+)?=(.*)$" flag) flags);
    in if matches == [ ] then null else builtins.elemAt (lib.last matches) 1;
  flagIsTrue = value: builtins.elem value [ "1" "ON" "TRUE" "YES" ];
  optimizedCompatibility = flagIsTrue (effectiveFlagValue "BUILD_OPT" cmakeFlags);
  implementationEnforceTiming = implementation.enforceTiming or null;
  checkedImplementationEnforceTiming =
    if implementationEnforceTiming == null || builtins.isBool implementationEnforceTiming then
      implementationEnforceTiming
    else
      throw "coyote-nix: implementation.enforceTiming must be a Boolean when specified";
  # Whether failed timing counts as a validation failure. It does unless
  # implementation.enforceTiming is false.
  validationTimingFlag = if checkedImplementationEnforceTiming == false then "0" else "1";
  # A strict build fails when validation fails; otherwise the bitstreams are
  # built anyway and carry the validation result.
  checkedStrict =
    if !builtins.isBool strict then
      throw "coyote-nix: strict must be a Boolean"
    else
      lib.warnIf (implementation ? signoffClassification)
        "coyote-nix: implementation.signoffClassification is no longer used and is ignored"
        strict;
  defaultDirectives = {
    opt = "project";
    place = "project";
    physOpt = "project";
    route = "project";
    postRoutePhysOpt = "project";
    finalRoute = "project";
  };
  implementationDirectives = defaultDirectives // (implementation.directives or { });
  implementationTopology = implementation.topology or { configurations = 1; regions = 1; };
  checkedImplementationTopology =
    if implementationTopology == { configurations = 1; regions = 1; } then implementationTopology else
      throw "coyote-nix: staged implementation currently supports exactly one configuration and one region";
  # Vivado 2025.1's router segfaults while building its netlist for V80
  # designs with a reconfigurable partition when it uses several threads
  # (route_design, Phase 1, rt::HARTNetlistBldrBase::buildNetlist). One
  # thread routes the same checkpoint cleanly, so routing on the V80 uses one.
  routeCores =
    phase: cores: if boardProfile.board == "v80" && phase == "route" then 1 else cores;
  implementationCores = implementation.resources.cores or 8;
  checkedImplementationCores = if builtins.isInt implementationCores && implementationCores > 0 then
    implementationCores
  else
    throw "coyote-nix: implementation.resources.cores must be a positive integer";
  incrementalReference = implementation.incrementalReference or null;
  checkedIncrementalReference =
    if incrementalReference == null then null
    else if boardProfile.board != "u280" then
      throw "coyote-nix: incremental implementation references support only U280"
    else if !lib.isDerivation incrementalReference then
      throw "coyote-nix: implementation.incrementalReference must be a derivation"
    else incrementalReference;
  effectivePcieGeneration = effectiveFlagValue "PCIE_GEN" cmakeFlags;
  implementationPcieGeneration = if effectivePcieGeneration == null then "4" else
    if builtins.elem effectivePcieGeneration [ "4" "5" ] then effectivePcieGeneration else
      throw "coyote-nix: PCIE_GEN must be 4 or 5";
  shellMetadataBase = pkgs.writeText "${pname}-shell-metadata-base.json" (
    builtins.toJSON {
      schemaVersion = 1;
      api = "coyote-nix.two-stage/v1";
      kind = "coyote-shell";
      inherit version xilinxVersion;
      board = boardProfile.board;
      platform = boardProfile.platform;
      coyotePlatform = boardProfile.coyotePlatform;
      fpgaArchitecture = boardProfile.fpgaArchitecture;
      fpgaPart = boardProfile.fpgaPart;
      flow = {
        buildStatic = false;
        buildShell = true;
        buildApp = false;
        enPr = true;
        enShellPblock = boardProfile.twoStage.enShellPblock;
        stages = boardProfile.twoStage.shellStageNames;
      };
      partialArtifacts = {
        shellSupported = boardProfile.twoStage.supportsShellPartial;
        shellExtension = boardProfile.twoStage.shellPartialExtension;
        appExtension = boardProfile.twoStage.appPartialExtension;
      };
      compatibility = {
        algorithm = "sha256";
        identityInputs = [
          "schema"
          "board"
          "fpgaArchitecture"
          "xilinxVersion"
          "export.cmake sha256"
          "shell_routed_locked.dcp sha256"
        ];
      };
      provenance = {
        coyoteSource = toString coyoteRoot;
        hardwareSource = toString hwSource;
        staticPath = toString staticPath;
        caller = provenance;
      } // subdivisionProvenance;
    }
  );

  installShellExport = ''
    mkdir -p "$out/checkpoints" "$out/reports" "$out/bitstreams" "$out/metadata"

    install -m0644 "$build_dir/export.cmake" "$out/export.cmake"
    cp -r "$build_dir/checkpoints/." "$out/checkpoints/"
    if [ -d "$build_dir/reports" ]; then
      cp -r "$build_dir/reports/." "$out/reports/"
    fi
    cp -r "$build_dir/bitstreams/." "$out/bitstreams/"

    export_cmake_sha256="$(sha256sum "$out/export.cmake" | cut -d ' ' -f 1)"
    locked_dcp_sha256="$(sha256sum "$out/checkpoints/shell_routed_locked.dcp" | cut -d ' ' -f 1)"
    compatibility_id="$(
      printf '%s\0' \
        'coyote-nix-shell-v1' \
        '${boardProfile.board}' \
        '${boardProfile.fpgaArchitecture}' \
        '${xilinxVersion}' \
        "$export_cmake_sha256" \
        "$locked_dcp_sha256" \
        | sha256sum | cut -d ' ' -f 1
    )"

    ${writeArtifactManifest {
      roots = [
        "$out/export.cmake"
        "$out/checkpoints"
        "$out/reports"
        "$out/bitstreams"
      ];
      output = "$out/metadata/artifacts.json";
    }}

    jq \
      --arg compatibilityId "$compatibility_id" \
      --arg exportCmakeSha256 "$export_cmake_sha256" \
      --arg shellRoutedLockedDcpSha256 "$locked_dcp_sha256" \
      --slurpfile artifacts "$out/metadata/artifacts.json" \
      '.compatibility += {
        id: $compatibilityId,
        exportCmakeSha256: $exportCmakeSha256,
        shellRoutedLockedDcpSha256: $shellRoutedLockedDcpSha256
      } | .artifacts = $artifacts[0]' \
      ${shellMetadataBase} > "$out/metadata/shell-base.json"

    bash ${../nix/tools/add-resident-service-metadata.sh} \
      "$out/export.cmake" \
      "$out/metadata/shell-base.json" \
      "$out/metadata/shell-resident.json"
    bash ${../nix/tools/add-coprocessor-metadata.sh} \
      "$out/export.cmake" \
      "$out/metadata/shell-resident.json" \
      "$out/metadata/shell.json"
    rm "$out/metadata/shell-base.json" "$out/metadata/shell-resident.json"
    printf '%s\n' "$compatibility_id" > "$out/metadata/compatibility-id"
  '';

  residentShellSynthesis = mkStage {
    pname = "${pname}-resident-shell-synth";
    board = boardProfile;
    inherit xilinxVersion;
    cmakeFlags = shellSynthesisCmakeFlags;
    buildCommands = [
      "make project"
      "make shell_synthesis_checkpoint"
    ];
    expectedPaths = [
      "checkpoints/shell/shell_synthed.dcp"
    ];
    extraInstallPhase = installCheckpointReports {
      checkpointDirs = [ "shell" ];
      reportDirs = [ "shell" ];
    };
    description = "Coyote ${boardProfile.platform} resident-shell synthesis checkpoint";
  };

  synthesisAnalysisRaw = mkStage {
    pname = "${pname}-synthesis-analysis-raw";
    board = boardProfile;
    inherit xilinxVersion;
    cmakeFlags = shellSynthesisCmakeFlags;
    preBuildSetup = copyPreviousStageSetup residentShellSynthesis { };
    buildCommands = [
      "make project"
      "make synthesis_analysis"
    ];
    expectedPaths = [
      "checkpoints/shell/shell_synthed.dcp"
      "reports/synthesis_analysis/complete"
      "reports/synthesis_analysis/summary.json"
      "reports/synthesis_analysis/timing_summary.rpt"
      "reports/synthesis_analysis/check_timing.rpt"
      "reports/synthesis_analysis/utilization.rpt"
      "reports/synthesis_analysis/high_fanout_nets.rpt"
      "reports/synthesis_analysis/setup_paths.rpt"
      "reports/synthesis_analysis/hold_paths.rpt"
    ];
    nativeBuildInputs = [
      pkgs.bash
      pkgs.jq
    ];
    extraInstallPhase = ''
      ${installCheckpointReports {
        checkpointDirs = [ "shell" ];
        reportDirs = [
          "shell"
          "synthesis_analysis"
        ];
      }}
      mkdir -p "$out/metadata"
      install -m0644 \
        "$out/reports/synthesis_analysis/summary.json" \
        "$out/metadata/raw-analysis.json"
    '';
    description = "Coyote ${boardProfile.platform} fast resident-shell synthesis analysis";
  };

  synthesisAnalysisMetadata = pkgs.writeText "${pname}-synthesis-analysis-package.json" (
    builtins.toJSON {
      schemaVersion = 1;
      api = "coyote-nix.synthesis-analysis/v1";
      kind = "coyote-shell-synthesis-assessment-package";
      predictiveOnly = true;
      inherit version xilinxVersion;
      board = boardProfile.board;
      platform = boardProfile.platform;
      fpgaArchitecture = boardProfile.fpgaArchitecture;
      fpgaPart = boardProfile.fpgaPart;
      policy = synthesisAnalysisPolicy;
      provenance = {
        coyoteSource = toString coyoteRoot;
        hardwareSource = toString hwSource;
        caller = provenance;
      };
    }
  );
  maximumLogicLevelsArg =
    if synthesisAnalysisPolicy.maximumLogicLevels == null then
      "null"
    else
      toString synthesisAnalysisPolicy.maximumLogicLevels;
  synthesisAnalysisStage =
    pkgs.runCommand "${pname}-synthesis-analysis"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.jq
        ];
        passthru.coyoteSynthesisAnalysis = {
          schemaVersion = 1;
          api = "coyote-nix.synthesis-analysis/v1";
          inherit (boardProfile) board fpgaArchitecture fpgaPart;
          inherit xilinxVersion;
          policy = synthesisAnalysisPolicy;
          metadata = "metadata/synthesis-analysis.json";
          classification = "metadata/classification";
          raw = synthesisAnalysisRaw;
        };
      }
      ''
        mkdir -p "$out/metadata"
        ln -s ${synthesisAnalysisRaw}/checkpoints "$out/checkpoints"
        ln -s ${synthesisAnalysisRaw}/reports "$out/reports"
        if [ -d ${synthesisAnalysisRaw}/logs ]; then
          ln -s ${synthesisAnalysisRaw}/logs "$out/logs"
        fi
        bash ${../nix/tools/assess-synthesis-analysis-result.sh} \
          ${synthesisAnalysisRaw}/metadata/raw-analysis.json \
          "$TMPDIR/assessment.json" \
          '${toString synthesisAnalysisPolicy.rejectSetupWnsBelow}' \
          '${toString synthesisAnalysisPolicy.passSetupWnsAtLeast}' \
          '${maximumLogicLevelsArg}'
        jq -s '.[0] + { package: .[1] }' \
          "$TMPDIR/assessment.json" \
          ${synthesisAnalysisMetadata} \
          > "$out/metadata/synthesis-analysis.json"
        bash ${../nix/tools/check-synthesis-assessment-result.sh} --validate-only \
          "$out/metadata/synthesis-analysis.json"
        jq -r '.classification' "$out/metadata/synthesis-analysis.json" \
          > "$out/metadata/classification"
      '';

  synthesisAnalysisGate =
    pkgs.runCommand "${pname}-synthesis-analysis-gate"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.jq
        ];
      }
      ''
        assessment=${synthesisAnalysisStage}/metadata/synthesis-analysis.json
        COYOTE_SYNTHESIS_ANALYSIS_PATH=${synthesisAnalysisStage} \
          bash ${../nix/tools/check-synthesis-assessment-result.sh} "$assessment"
        mkdir -p "$out/metadata"
        cp "$assessment" "$out/metadata/synthesis-analysis.json"
        cp ${synthesisAnalysisStage}/metadata/classification \
          "$out/metadata/classification"
      '';

  synthesisAnalysisReuseSetup = copyPreviousStageSetup residentShellSynthesis { };

  synth = mkStage {
    pname = "${pname}-synth";
    board = boardProfile;
    inherit xilinxVersion;
    cmakeFlags = shellSynthesisCmakeFlags;
    preBuildSetup = synthesisAnalysisReuseSetup;
    buildCommands = [
      "make project"
      "make synth"
    ];
    expectedPaths = [
      "export.cmake"
      "checkpoints/shell/shell_synthed.dcp"
      "checkpoints/config_0/user_synthed_c0_0.dcp"
    ];
    extraInstallPhase = installCheckpointReports {
      checkpointDirs = [
        "shell"
        "config_0"
      ];
      reportDirs = [
        "shell"
        "config_0"
      ];
    };
    description = "Coyote ${boardProfile.platform} PR shell synthesis stage";
  };

  timingOracleMetadata = pkgs.writeText "${pname}-timing-oracle-package.json" (
    builtins.toJSON {
      schemaVersion = 1;
      api = "coyote-nix.timing-oracle/v1";
      kind = "coyote-shell-timing-oracle";
      predictiveOnly = true;
      inherit version xilinxVersion;
      board = boardProfile.board;
      platform = boardProfile.platform;
      fpgaArchitecture = boardProfile.fpgaArchitecture;
      fpgaPart = boardProfile.fpgaPart;
      policy = timingOraclePolicy;
      provenance = {
        coyoteSource = toString coyoteRoot;
        hardwareSource = toString hwSource;
        staticPath = toString staticPath;
        caller = provenance;
      };
    }
  );

  timingOracleStage = mkStage {
    pname = "${pname}-timing-oracle";
    board = boardProfile;
    inherit xilinxVersion;
    cmakeFlags = shellCmakeFlags;
    preBuildSetup = copyPreviousStageSetup synth { };
    buildCommands = [
      "make project"
      "make timing_oracle"
    ];
    expectedPaths = [
      "checkpoints/timing_oracle/shell_linked.dcp"
      "checkpoints/timing_oracle/shell_opted.dcp"
      "reports/timing_oracle/complete"
      "reports/timing_oracle/summary.json"
      "reports/timing_oracle/post_opt_qor_assessment.rpt"
    ];
    nativeBuildInputs = [
      pkgs.bash
      pkgs.jq
    ];
    extraInstallPhase = ''
      ${installCheckpointReports {
        copyAllCheckpoints = true;
        copyAllReports = true;
      }}
      mkdir -p "$out/metadata"
      bash ${../nix/tools/check-timing-oracle-result.sh} --validate-only \
        "$out/reports/timing_oracle/summary.json"
      if jq -e '.postPlace != null' \
          "$out/reports/timing_oracle/summary.json" >/dev/null; then
        for artifact in \
          checkpoints/timing_oracle/shell_placed_runtime_optimized.dcp \
          reports/timing_oracle/post_place_qor_assessment.rpt \
          reports/timing_oracle/post_place_utilization.rpt \
          reports/timing_oracle/post_place_timing_summary.rpt; do
          if [ ! -f "$out/$artifact" ]; then
            echo "ERROR: timing oracle summary declares placement but artifact is missing: $artifact" >&2
            exit 1
          fi
        done
      fi
      jq -s '.[0] + { package: .[1] }' \
        "$out/reports/timing_oracle/summary.json" \
        ${timingOracleMetadata} \
        > "$out/metadata/timing-oracle.json"
      jq -r '.classification' "$out/metadata/timing-oracle.json" \
        > "$out/metadata/classification"
    '';
    extraAttrs = {
      passthru.coyoteTimingOracle = {
        schemaVersion = 1;
        api = "coyote-nix.timing-oracle/v1";
        inherit (boardProfile) board fpgaArchitecture fpgaPart;
        inherit xilinxVersion;
        policy = timingOraclePolicy;
        metadata = "metadata/timing-oracle.json";
        classification = "metadata/classification";
      };
    };
    description = "Coyote ${boardProfile.platform} predictive shell timing oracle";
  };

  timingOracleGate =
    pkgs.runCommand "${pname}-timing-oracle-gate"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.jq
        ];
      }
      ''
        summary=${timingOracleStage}/metadata/timing-oracle.json
        COYOTE_TIMING_ORACLE_PATH=${timingOracleStage} \
          bash ${../nix/tools/check-timing-oracle-result.sh} "$summary"
        mkdir -p "$out/metadata"
        cp "$summary" "$out/metadata/timing-oracle.json"
        cp ${timingOracleStage}/metadata/classification "$out/metadata/classification"
      '';

  # Collects the checkpoints a link stage starts from.
  mkInputBundle = { name, commands }:
    pkgs.runCommand "${pname}-${name}-inputs" { } ''
      mkdir -p "$out/checkpoints/shell" "$out/checkpoints/config_0"
      ${commands}
    '';

  outerInputs = if hasSubdivisionParent && checkedSubdivisionReference == null then mkInputBundle {
    name = "shell";
    commands = ''
      cp ${staticPath}/static_routed_locked_${boardProfile.platform}.dcp \
        "$out/checkpoints/static_routed_locked_${boardProfile.platform}.dcp"
      cp ${synth}/checkpoints/shell/shell_synthed.dcp "$out/checkpoints/shell/"
      cp ${synth}/checkpoints/config_0/user_synthed_c0_0.dcp "$out/checkpoints/config_0/"
    '';
  } else null;

  synthesizedCheckpoints = [
    "checkpoints/shell/shell_synthed.dcp"
    "checkpoints/config_0/user_synthed_c0_0.dcp"
  ];

  # Copies a stage's reports, which not every stage writes.
  installReports = directory: ''
    mkdir -p "$out/${directory}"
    if [ -d "$build_dir/${directory}" ]; then
      cp -a "$build_dir/${directory}/." "$out/${directory}/"
    fi
  '';

  outerLink = if outerInputs == null then null else mkStage {
    pname = "${pname}-shell-link";
    board = boardProfile;
    inherit xilinxVersion;
    cores = checkedImplementationCores;
    cmakeFlags = shellImplementationBaseFlags ++ [ "-DSTATIC_PATH=${outerInputs}/checkpoints" ];
    preBuildSetup = importStageFiles {
      previousStage = outerInputs;
      paths = synthesizedCheckpoints;
    };
    buildCommands = [ "vivado -mode tcl -source \"$build_dir/link.tcl\" -notrace" ];
    expectedPaths = [ "checkpoints/shell_linked.dcp" ];
    extraInstallPhase = ''
      mkdir -p "$out/checkpoints"
      cp "$build_dir/checkpoints/shell_linked.dcp" "$out/checkpoints/"
      ${installReports "reports"}
    '';
  };

  # One Vivado implementation phase (opt, place, route or validate) of Coyote's
  # physical_stage target, starting from the predecessor's output checkpoint.
  mkPhysicalStage = {
    name, unit, phase, predecessor, inputPath, outputPath, extraFlags,
    incrementalMode ? "none",
    extraPreBuildSetup ? "",
  }:
    let
      reportPrefix = if phase == "validate" then "shell" else "shell_${phase}";
      reportDirectory = if unit == "config_0" then "reports/config_0" else "reports";
      reportSuffix = if unit == "config_0" then "_c0" else "";
      physicalPath = "${reportDirectory}/${reportPrefix}_physical${reportSuffix}.json";
    in mkStage {
      pname = "${pname}-${name}-${phase}";
      board = boardProfile;
      inherit xilinxVersion;
      cores = routeCores phase checkedImplementationCores;
      checkTimingLog = false;
      cmakeFlags = shellImplementationBaseFlags ++ [
        "-DIMPLEMENTATION_PHASE:STRING=${phase}"
        "-DIMPLEMENTATION_INPUT_DCP:FILEPATH=$build_dir/${inputPath}"
        "-DIMPLEMENTATION_OUTPUT_DCP:FILEPATH=$build_dir/${outputPath}"
        "-DIMPLEMENTATION_COMPLETION_PATH:FILEPATH=$build_dir/checkpoints/${name}_${phase}_complete"
        "-DIMPLEMENTATION_REPORT_DIR:PATH=$build_dir/${reportDirectory}"
        "-DIMPLEMENTATION_REPORT_SUFFIX:STRING=${reportSuffix}"
        "-DIMPLEMENTATION_VALIDATION_SUMMARY:FILEPATH=$build_dir/${reportDirectory}/validation.json"
        "-DIMPLEMENTATION_TELEMETRY_PATH:FILEPATH=$build_dir/${physicalPath}"
      ] ++ lib.optionals (incrementalMode != "none") [
        "-DIMPLEMENTATION_INCREMENTAL_MODE:STRING=${incrementalMode}"
      ] ++ extraFlags;
      preBuildSetup = ''
        ${importStageFiles {
          previousStage = predecessor;
          paths = [ inputPath ];
        }}
        ${extraPreBuildSetup}
        ${lib.optionalString (!collectPhysicalQorAssessment && builtins.elem phase [ "opt" "place" ]) ''
          chmod u+w "$build_dir/base.tcl" "$build_dir/physical_stage.tcl"
          ${pkgs.python3}/bin/python3 \
            ${../nix/tools/patch-u280-vivado-2023.2-physical-stage.py} \
            "$build_dir/base.tcl" "$build_dir/physical_stage.tcl"
        ''}
      '';
      buildCommands = [ "make physical_stage" ];
      expectedPaths = [ outputPath "checkpoints/${name}_${phase}_complete" physicalPath ]
        ++ lib.optionals (phase == "validate") [ "${reportDirectory}/validation.json" ];
      extraInstallPhase = ''
        mkdir -p "$out/$(dirname ${outputPath})"
        cp "$build_dir/${outputPath}" "$out/${outputPath}"
        ${installReports reportDirectory}
      '';
    };

  optFlags = [ "-DIMPLEMENTATION_OPT_DIRECTIVE:STRING=${implementationDirectives.opt}" ];
  placeFlags = lib.optionals combineOptPlace optFlags ++ [
    "-DIMPLEMENTATION_PLACE_DIRECTIVE:STRING=${implementationDirectives.place}"
    "-DIMPLEMENTATION_PHYS_OPT_DIRECTIVE:STRING=${implementationDirectives.physOpt}"
  ];
  routeFlags = [
    "-DIMPLEMENTATION_ROUTE_DIRECTIVE:STRING=${implementationDirectives.route}"
    "-DIMPLEMENTATION_POST_ROUTE_PHYS_OPT_DIRECTIVE:STRING=${implementationDirectives.postRoutePhysOpt}"
    "-DIMPLEMENTATION_FINAL_ROUTE_DIRECTIVE:STRING=${implementationDirectives.finalRoute}"
  ];
  validateFlags = label: [
    "-DIMPLEMENTATION_ENFORCE_TIMING:STRING=${validationTimingFlag}"
    "-DIMPLEMENTATION_LABEL:STRING=${label}"
    "-DIMPLEMENTATION_DRC_NAME:STRING=${label}_bitstream_checks"
  ];

  outerOpt = if outerLink == null || combineOptPlace then null else mkPhysicalStage {
    name = "shell"; unit = "shell"; phase = "opt"; predecessor = outerLink;
    inputPath = "checkpoints/shell_linked.dcp"; outputPath = "checkpoints/shell_opted.dcp";
    extraFlags = optFlags;
  };
  outerPlace = if outerLink == null then null else mkPhysicalStage {
    name = "shell"; unit = "shell"; phase = "place";
    predecessor = if combineOptPlace then outerLink else outerOpt;
    inputPath = if combineOptPlace then "checkpoints/shell_linked.dcp" else "checkpoints/shell_opted.dcp";
    outputPath = "checkpoints/shell_phys_opted.dcp";
    extraFlags = placeFlags;
  };
  outerRoute = if outerPlace == null then null else mkPhysicalStage {
    name = "shell"; unit = "shell"; phase = "route"; predecessor = outerPlace;
    inputPath = "checkpoints/shell_phys_opted.dcp";
    outputPath = "checkpoints/shell_routed_unvalidated.dcp";
    extraFlags = routeFlags;
  };
  outerValidate = if outerRoute == null then null else mkPhysicalStage {
    name = "shell"; unit = "shell"; phase = "validate"; predecessor = outerRoute;
    inputPath = "checkpoints/shell_routed_unvalidated.dcp";
    outputPath = "checkpoints/shell_routed.dcp";
    extraFlags = validateFlags "routed_shell";
  };
  outerValidationGate = if outerValidate == null then null else mkValidationResult {
    pname = "${pname}-shell-validation";
    stage = outerValidate;
    validationPath = "reports/validation.json";
    strict = checkedStrict;
  };
  routed = outerValidationGate;

  staticSynthesizedCheckpoint =
    "checkpoints/static_synthed_${boardProfile.platform}_gen${toString implementationPcieGeneration}.dcp";
  dynamicInputs = mkInputBundle {
    name = "config_0";
    commands = ''
      ${lib.optionalString (outerValidate != null) ''
        test -e ${outerValidationGate}/metadata/outcome
        cp ${outerValidate}/checkpoints/shell_routed.dcp "$out/checkpoints/"
      ''}${lib.optionalString (checkedSubdivisionReference != null) ''
        ${pkgs.python3}/bin/python3 ${../nix/tools/check-subdivision-reference.py} \
          ${lib.escapeShellArg "${checkedSubdivisionReference.checkpoint}"} \
          ${checkedSubdivisionReference.checkpointSha256} \
          ${lib.escapeShellArg "${checkedSubdivisionReference.staticCheckpoint}"} \
          ${checkedSubdivisionReference.staticCheckpointSha256} \
          ${lib.escapeShellArg "${staticPath}/static_routed_locked_${boardProfile.platform}.dcp"}
        cp ${lib.escapeShellArg "${checkedSubdivisionReference.checkpoint}"} "$out/checkpoints/shell_routed.dcp"
      ''}
      cp ${synth}/checkpoints/shell/shell_synthed.dcp "$out/checkpoints/shell/"
      cp ${synth}/checkpoints/config_0/user_synthed_c0_0.dcp "$out/checkpoints/config_0/"
      ${lib.optionalString (boardProfile.fpgaArchitecture == "versal") ''
        cp ${staticPath}/static_synthed_${boardProfile.platform}_gen${toString implementationPcieGeneration}.dcp \
          "$out/${staticSynthesizedCheckpoint}"
      ''}
    '';
  };
  greyboxScript = pkgs.writeText "coyote-greybox-applications.tcl" ''
    set dcp checkpoints/config_0/shell_linked_c0.dcp
    open_checkpoint $dcp
    set cells [get_cells -quiet inst_shell/inst_dynamic/inst_user_wrapper_*]
    if {[llength $cells] == 0} { error "no application partitions to grey-box" }
    foreach cell $cells {
      update_design -cell $cell -black_box
      update_design -cell $cell -buffer_ports
    }
    write_checkpoint -force $dcp
  '';
  greyboxCommand = "vivado -mode batch -nojournal -log greybox-applications.log -source ${greyboxScript}";
  dynamicLink = mkStage {
    pname = "${pname}-config-0-link";
    board = boardProfile; inherit xilinxVersion; cores = checkedImplementationCores;
    cmakeFlags = shellImplementationBaseFlags ++ lib.optionals (boardProfile.fpgaArchitecture == "versal") [ "-DSTATIC_PATH=${dynamicInputs}/checkpoints" ];
    preBuildSetup = importStageFiles {
      previousStage = dynamicInputs;
      paths = synthesizedCheckpoints ++ lib.optionals hasSubdivisionParent [ "checkpoints/shell_routed.dcp" ];
    };
    buildCommands = [ "make dynamic_link" ] ++ lib.optional greyboxApplications greyboxCommand;
    expectedPaths = [ "checkpoints/dynamic_link_complete" "checkpoints/config_0/shell_linked_c0.dcp" ];
    extraInstallPhase = ''
      mkdir -p "$out/checkpoints/config_0"
      cp "$build_dir/checkpoints/config_0/shell_linked_c0.dcp" "$out/checkpoints/config_0/"
      ${installReports "reports/config_0"}
    '';
  };
  dynamicOpt = if combineOptPlace then null else mkPhysicalStage {
    name = "config_0"; unit = "config_0"; phase = "opt"; predecessor = dynamicLink;
    inputPath = "checkpoints/config_0/shell_linked_c0.dcp";
    outputPath = "checkpoints/config_0/shell_opted_c0.dcp";
    extraFlags = optFlags;
  };
  dynamicPlace = mkPhysicalStage {
    name = "config_0"; unit = "config_0"; phase = "place";
    predecessor = if combineOptPlace then dynamicLink else dynamicOpt;
    inputPath = if combineOptPlace then "checkpoints/config_0/shell_linked_c0.dcp" else "checkpoints/config_0/shell_opted_c0.dcp";
    outputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
    extraFlags = placeFlags;
  };
  dynamicRoute = mkPhysicalStage {
    name = "config_0"; unit = "config_0"; phase = "route"; predecessor = dynamicPlace;
    inputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
    outputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
    extraFlags = routeFlags;
  };
  dynamicValidate = mkPhysicalStage {
    name = "config_0"; unit = "config_0"; phase = "validate"; predecessor = dynamicRoute;
    inputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
    outputPath = "checkpoints/config_0/shell_routed_c0.dcp";
    extraFlags = validateFlags "config_0_routed_shell";
  };
  dynamicValidationGate = mkValidationResult {
    pname = "${pname}-dynamic-validation";
    stage = dynamicValidate;
    validationPath = "reports/config_0/validation.json";
    strict = checkedStrict;
  };

  # Experimental (U280): implement config 0 again, reusing placement and
  # routing from the routed config 0 checkpoint of an earlier build.
  incrementalReferenceSetup = reference: ''
    install -D -m0644 ${reference}/checkpoints/config_0/shell_routed_c0.dcp \
      "$build_dir/checkpoints/config_0/incremental_reference.dcp"
  '';
  incrementalOpt = if checkedIncrementalReference == null then null else mkPhysicalStage {
    name = "config_0_incremental"; unit = "config_0"; phase = "opt"; predecessor = dynamicLink;
    inputPath = "checkpoints/config_0/shell_linked_c0.dcp";
    outputPath = "checkpoints/config_0/shell_opted_c0.dcp";
    incrementalMode = "reference";
    extraPreBuildSetup = incrementalReferenceSetup checkedIncrementalReference;
    extraFlags = optFlags ++ [
      "-DIMPLEMENTATION_INCREMENTAL_REFERENCE_DCP:FILEPATH=$build_dir/checkpoints/config_0/incremental_reference.dcp"
    ];
  };
  incrementalPlace = if incrementalOpt == null then null else mkPhysicalStage {
    name = "config_0_incremental"; unit = "config_0"; phase = "place"; predecessor = incrementalOpt;
    inputPath = "checkpoints/config_0/shell_opted_c0.dcp";
    outputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
    incrementalMode = "reference";
    extraFlags = placeFlags;
  };
  incrementalRoute = if incrementalPlace == null then null else mkPhysicalStage {
    name = "config_0_incremental"; unit = "config_0"; phase = "route"; predecessor = incrementalPlace;
    inputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
    outputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
    incrementalMode = "reference";
    extraFlags = routeFlags;
  };
  incrementalValidate = if incrementalRoute == null then null else mkPhysicalStage {
    name = "config_0_incremental"; unit = "config_0"; phase = "validate"; predecessor = incrementalRoute;
    inputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
    outputPath = "checkpoints/config_0/shell_routed_c0.dcp";
    incrementalMode = "reference";
    extraFlags = validateFlags "config_0_incremental_routed_shell";
  };
  incrementalGate = if incrementalValidate == null then null else mkValidationResult {
    pname = "${pname}-incremental-validation";
    stage = incrementalValidate;
    validationPath = "reports/config_0/validation.json";
    strict = checkedStrict;
  };

  dynamic = mkStage {
    pname = "${pname}-dynamic";
    board = boardProfile; inherit xilinxVersion; cores = checkedImplementationCores;
    checkTimingLog = false;
    cmakeFlags = shellImplementationBaseFlags ++ [ "-DIMPLEMENTATION_PHASE:STRING=finalize" ];
    preBuildSetup = ''
      test -e ${dynamicValidationGate}/metadata/outcome
      ${copyPreviousStageSetup dynamicValidate { }}
    '';
    buildCommands = [ "make dynamic_finalize" ];
    expectedPaths = [
      "checkpoints/config_0/shell_routed_c0.dcp"
      "checkpoints/shell_routed_locked.dcp"
      "checkpoints/dynamic_finalize_complete"
    ] ++ lib.optionals (boardProfile.fpgaArchitecture == "ultrascale_plus") [ "checkpoints/shell_recombined.dcp" ]
      ++ lib.optionals (boardProfile.fpgaArchitecture == "versal") [ "checkpoints/shell_routed.dcp" ];
    extraInstallPhase = ''
      mkdir -p "$out/checkpoints/config_0"
      cp "$build_dir/checkpoints/config_0/shell_routed_c0.dcp" "$out/checkpoints/config_0/"
      cp "$build_dir/checkpoints/shell_routed_locked.dcp" "$out/checkpoints/"
      ${installReports "reports/config_0"}
      ${lib.optionalString (boardProfile.fpgaArchitecture == "ultrascale_plus") ''cp "$build_dir/checkpoints/shell_recombined.dcp" "$out/checkpoints/"''}
      ${lib.optionalString (boardProfile.fpgaArchitecture == "versal") ''cp "$build_dir/checkpoints/shell_routed.dcp" "$out/checkpoints/"''}
    '';
  };

  contract = {
    schemaVersion = 1;
    api = "coyote-nix.two-stage/v1";
    kind = "shell";
    inherit version xilinxVersion;
    board = boardProfile.board;
    platform = boardProfile.platform;
    coyotePlatform = boardProfile.coyotePlatform;
    fpgaArchitecture = boardProfile.fpgaArchitecture;
    fpgaPart = boardProfile.fpgaPart;
    coyoteSource = toString coyoteRoot;
    hardwareSource = toString hwSource;
    enPr = true;
    enShellPblock = boardProfile.twoStage.enShellPblock;
    stageNames = boardProfile.twoStage.shellStageNames;
    expectedBitstreams = shellExpectedBitstreams;
    appPartialExtension = boardProfile.twoStage.appPartialExtension;
    metadataPath = "metadata/shell.json";
    compatibilityIdPath = "metadata/compatibility-id";
    validationPath = "metadata/validation.json";
    staticPath = toString staticPath;
    strict = checkedStrict;
    inherit shellCmakeFlags shellSynthesisCmakeFlags;
    synthesisAnalysis = {
      canonicalBuildDependency = false;
      policy = synthesisAnalysisPolicy;
      synthesis = residentShellSynthesis;
      raw = synthesisAnalysisRaw;
      stage = synthesisAnalysisStage;
      gate = synthesisAnalysisGate;
      metadata = "metadata/synthesis-analysis.json";
      classification = "metadata/classification";
    };
    timingOracle = {
      canonicalBuildDependency = false;
      policy = timingOraclePolicy;
      stage = timingOracleStage;
      gate = timingOracleGate;
      metadata = "metadata/timing-oracle.json";
      classification = "metadata/classification";
    };
    physical = {
      strict = checkedStrict;
      resources.cores = checkedImplementationCores;
      directives = implementationDirectives;
      inherit combineOptPlace;
      image = "self";
      incremental = if checkedIncrementalReference == null then null else {
        experimental = true;
        reference = checkedIncrementalReference;
        stages = {
          opt = incrementalOpt;
          place = incrementalPlace;
          route = incrementalRoute;
          validate = incrementalValidate;
          gate = incrementalGate;
        };
      };
      units = {
        config_0 = {
          inputs = dynamicInputs;
          link = dynamicLink;
          opt = dynamicOpt;
          place = dynamicPlace;
          route = dynamicRoute;
          validate = dynamicValidate;
          gate = dynamicValidationGate;
          finalize = dynamic;
        };
      } // lib.optionalAttrs (outerLink != null) {
        shell = {
          inputs = outerInputs;
          link = outerLink;
          opt = outerOpt;
          place = outerPlace;
          route = outerRoute;
          validate = outerValidate;
          gate = outerValidationGate;
        };
      };
    } // subdivisionProvenance;
  };

  final = mkStage {
    inherit pname xilinxVersion;
    board = boardProfile;
    cores = checkedImplementationCores;
    checkTimingLog = false;
    cmakeFlags = shellCmakeFlags;
    preBuildSetup = copyPreviousStageSetup dynamic { };
    buildCommands = [
      (finalBitgenCommand shellExpectedBitstreams)
    ];
    expectedPaths = [
      "export.cmake"
      "checkpoints/shell_routed_locked.dcp"
    ]
    ++ map (artifact: "bitstreams/${artifact}") shellExpectedBitstreams;
    nativeBuildInputs = [ pkgs.jq ];
    extraInstallPhase = ''
      ${installShellExport}
      ${installValidationResult dynamicValidationGate}
    '';
    extraAttrs = {
      passthru.coyoteTwoStage = contract // {
        stages = {
          inherit residentShellSynthesis synth dynamic;
          implementationInputs = dynamicInputs;
          link = dynamicLink;
          opt = dynamicOpt;
          place = dynamicPlace;
          route = dynamicRoute;
          validate = dynamicValidate;
          validationGate = dynamicValidationGate;
          finalize = dynamic;
          timingOracle = timingOracleStage;
          timingGate = timingOracleGate;
          incremental = if checkedIncrementalReference == null then null else {
            opt = incrementalOpt;
            place = incrementalPlace;
            route = incrementalRoute;
            validate = incrementalValidate;
            gate = incrementalGate;
          };
        }
        // lib.optionalAttrs synthesisAnalysisPolicy.enable {
          synthesisAnalysisRaw = synthesisAnalysisRaw;
          synthesisAnalysis = synthesisAnalysisStage;
          synthesisGate = synthesisAnalysisGate;
        }
        // lib.optionalAttrs (routed != null) { inherit routed; };
      };
    };
    description = "Reusable Coyote ${boardProfile.platform} PR shell export";
  };

in
builtins.seq checkedSubdivisionReference final
