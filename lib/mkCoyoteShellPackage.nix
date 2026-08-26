{
  pkgs,
  tools,
  coyoteRoot,
  hwSource,
  xilinxShareRoot,
  xilinxShell ? null,
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
}:

let
  lib = pkgs.lib;
  boardProfiles = import ./coyoteBoardProfiles.nix;
  boardProfile =
    boardProfiles.${board}
      or (throw "coyote-nix: mkCoyoteShellPackage supports only u280 and v80, not ${board}");

  stageHelpers = import ./coyoteHwStageHelpers.nix {
    inherit
      pkgs
      tools
      coyoteRoot
      hwSource
      xilinxShareRoot
      xilinxShell
      version
      ;
  };

  inherit (stageHelpers)
    copyPreviousStageSetup
    finalBitgenCommand
    implementationStageTool
    incrementalReferenceTool
    importImplementationStageArtifacts
    installCheckpointReports
    mkImplementationStageGate
    mkStage
    writeArtifactManifest
    writeImplementationStageManifest
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
      throw "coyote-nix: immutable physical staging currently supports exactly one configuration and one region";
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
      throw "coyote-nix: implementation.incrementalReference must be an immutable Nix derivation"
    else incrementalReference;
  effectivePcieGeneration = effectiveFlagValue "PCIE_GEN" cmakeFlags;
  implementationPcieGeneration = if effectivePcieGeneration == null then "4" else
    if builtins.elem effectivePcieGeneration [ "4" "5" ] then effectivePcieGeneration else
      throw "coyote-nix: PCIE_GEN must be 4 or 5";
  implementationContextWithoutId = {
    board = boardProfile.board;
    architecture = boardProfile.fpgaArchitecture;
    part = boardProfile.fpgaPart;
    flow = "build-shell";
    topology = checkedImplementationTopology;
    sourceId = builtins.hashString "sha256" (toString hwSource);
    coyoteSourceId = builtins.hashString "sha256" (toString coyoteRoot);
    constraintsId = builtins.hashString "sha256" (builtins.toJSON {
      source = toString hwSource;
      static = toString staticPath;
      flags = shellImplementationBaseFlags;
    });
    toolId = implementation.xilinxInstallationId or "vivado-${xilinxVersion}@${toString xilinxShareRoot}";
    toolVersion = xilinxVersion;
  };
  implementationContext = implementationContextWithoutId // {
    id = builtins.hashString "sha256" (builtins.toJSON implementationContextWithoutId);
  };
  implementationContextFile = pkgs.writeText "${pname}-implementation-context.json" (builtins.toJSON implementationContext);
  mkImplementationSpec =
    {
      name,
      phase,
      predecessorPath ? null,
      artifacts,
      strategy ? { },
      outcome ? "complete",
      outcomePath ? null,
      unit ? "config_0",
      telemetryPhysicalPath ? null,
    }:
    let
      telemetryArtifacts = lib.optionals (phase != "inputs") ([
        { role = "execution-evidence"; path = "metadata/execution.json"; }
        { role = "raw-resource-measurement"; path = "metadata/gnu-time.txt"; }
        { role = "command-stdout"; path = "logs/command.stdout.log"; }
        { role = "command-stderr"; path = "logs/command.stderr.log"; }
        { role = "normalized-telemetry"; path = "metadata/telemetry.json"; }
      ] ++ lib.optionals (telemetryPhysicalPath != null) [
        { role = "physical-observations"; path = telemetryPhysicalPath; }
      ]);
    in
    pkgs.writeText "${pname}-${name}-stage-spec.json" (builtins.toJSON {
      schemaVersion = 2;
      inherit phase strategy outcome unit;
      artifacts = artifacts ++ telemetryArtifacts;
      context = implementationContext;
      resources.cores = checkedImplementationCores;
      predecessorPath = if predecessorPath == null then null else toString predecessorPath;
      outcomePath = outcomePath;
      telemetry = if phase == "inputs" then null else {
        path = "metadata/telemetry.json";
        executionPath = "metadata/execution.json";
        physicalPath = telemetryPhysicalPath;
      };
    });
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
      };
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

  synthesisAnalysisRaw = mkStage {
    pname = "${pname}-synthesis-analysis-raw";
    board = boardProfile;
    inherit xilinxVersion;
    cmakeFlags = shellSynthesisCmakeFlags;
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

  synthesisAnalysisGateDependency =
    lib.optionalString (synthesisAnalysisPolicy.enable && synthesisAnalysisPolicy.enforce)
      ''
        test -e ${synthesisAnalysisGate}/metadata/synthesis-analysis.json
      '';
  synthesisAnalysisReuseSetup = lib.optionalString synthesisAnalysisPolicy.enable (
    copyPreviousStageSetup synthesisAnalysisRaw { }
  );

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
    preBuildSetup = ''
      ${synthesisAnalysisGateDependency}
      ${copyPreviousStageSetup synth { }}
    '';
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

  timingGateDependency = lib.optionalString timingOraclePolicy.enforce ''
    test -e ${timingOracleGate}/metadata/timing-oracle.json
  '';

  mkInputBundle = { name, artifacts, commands }:
    let spec = mkImplementationSpec {
      inherit artifacts;
      name = "${name}-inputs";
      phase = "inputs";
      unit = name;
    };
    in pkgs.runCommand "${pname}-${name}-inputs" { nativeBuildInputs = [ pkgs.python3 ]; } ''
      mkdir -p "$out/checkpoints/shell" "$out/checkpoints/config_0" "$out/metadata"
      ${commands}
      ${pkgs.python3}/bin/python ${implementationStageTool} write ${spec} "$out" "$out"
    '';

  outerInputs = if boardProfile.fpgaArchitecture == "ultrascale_plus" then mkInputBundle {
    name = "shell";
    artifacts = [
      { role = "static-locked-checkpoint"; path = "checkpoints/static_routed_locked_${boardProfile.platform}.dcp"; }
      { role = "shell-synthesized-checkpoint"; path = "checkpoints/shell/shell_synthed.dcp"; }
      { role = "seed-synthesized-checkpoint"; path = "checkpoints/config_0/user_synthed_c0_0.dcp"; }
    ];
    commands = ''
      cp ${staticPath}/static_routed_locked_${boardProfile.platform}.dcp \
        "$out/checkpoints/static_routed_locked_${boardProfile.platform}.dcp"
      cp ${synth}/checkpoints/shell/shell_synthed.dcp "$out/checkpoints/shell/"
      cp ${synth}/checkpoints/config_0/user_synthed_c0_0.dcp "$out/checkpoints/config_0/"
    '';
  } else null;

  outerLinkSpec = if outerInputs == null then null else mkImplementationSpec {
    name = "shell-link";
    phase = "link";
    unit = "shell";
    predecessorPath = outerInputs;
    artifacts = [ { role = "linked-checkpoint"; path = "checkpoints/shell_linked.dcp"; } ];
  };
  outerLink = if outerInputs == null then null else mkStage {
    pname = "${pname}-shell-link";
    board = boardProfile;
    inherit xilinxVersion;
    cores = checkedImplementationCores;
    cmakeFlags = shellImplementationBaseFlags ++ [ "-DSTATIC_PATH=${outerInputs}/checkpoints" ];
    preBuildSetup = ''
      ${timingGateDependency}
      ${importImplementationStageArtifacts {
        previousStage = outerInputs;
        roles = [ "shell-synthesized-checkpoint" "seed-synthesized-checkpoint" ];
        expectedPhase = "inputs";
        expectedContext = implementationContext.id;
      }}
    '';
    buildCommands = [ "vivado -mode tcl -source \"$build_dir/link.tcl\" -notrace" ];
    expectedPaths = [ "checkpoints/shell_linked.dcp" ];
    nativeBuildInputs = [ pkgs.python3 ];
    extraInstallPhase = ''
      mkdir -p "$out/checkpoints" "$out/metadata"
      cp "$build_dir/checkpoints/shell_linked.dcp" "$out/checkpoints/"
      ${writeImplementationStageManifest { spec = outerLinkSpec; }}
    '';
  };

  mkPhysicalStage = {
    name, unit, phase, predecessor, predecessorPhase, predecessorRole,
    inputPath, outputPath, outputRole, strategy, extraFlags,
    incrementalMode ? "none", incrementalEvidence ? false,
    extraPreBuildSetup ? "",
  }:
    let
      reportPrefix = if phase == "validate" then "shell" else "shell_${phase}";
      reportDirectory = if unit == "config_0" then "reports/config_0" else "reports";
      reportSuffix = if unit == "config_0" then "_c0" else "";
      physicalPath = "${reportDirectory}/${reportPrefix}_physical${reportSuffix}.json";
      phaseArtifacts = [
        { role = "${phase}-utilization-report"; path = "${reportDirectory}/${reportPrefix}_utilization${reportSuffix}.rpt"; }
        { role = "${phase}-timing-summary-report"; path = "${reportDirectory}/${reportPrefix}_timing_summary${reportSuffix}.rpt"; }
      ] ++ lib.optionals (builtins.elem phase [ "opt" "place" ]) [
        { role = "${phase}-qor-assessment-report"; path = "${reportDirectory}/${reportPrefix}_qor_assessment${reportSuffix}.rpt"; }
      ] ++ lib.optionals (phase == "place" && boardProfile.board == "v80") [
        { role = "place-diagnosis-observations"; path = "${reportDirectory}/${reportPrefix}_diagnosis${reportSuffix}.json"; }
        { role = "place-congestion-report"; path = "${reportDirectory}/${reportPrefix}_congestion${reportSuffix}.rpt"; }
        { role = "place-complexity-report"; path = "${reportDirectory}/${reportPrefix}_complexity${reportSuffix}.rpt"; }
        { role = "place-logic-level-report"; path = "${reportDirectory}/${reportPrefix}_logic_levels${reportSuffix}.rpt"; }
        { role = "place-high-fanout-report"; path = "${reportDirectory}/${reportPrefix}_high_fanout${reportSuffix}.rpt"; }
      ] ++ lib.optionals (builtins.elem phase [ "route" "validate" ]) [
        { role = "${phase}-route-status-report"; path = "${reportDirectory}/${reportPrefix}_route_status${reportSuffix}.rpt"; }
      ] ++ lib.optionals (incrementalMode == "reference" && builtins.elem phase [ "place" "route" ]) [
        { role = "incremental-reuse-report"; path = "${reportDirectory}/${reportPrefix}_incremental_reuse${reportSuffix}.rpt"; }
      ] ++ lib.optionals incrementalEvidence [
        { role = "incremental-reference-evidence"; path = "metadata/incremental-reference.json"; }
      ];
      spec = mkImplementationSpec {
      inherit phase strategy unit;
      name = "${name}-${phase}";
      predecessorPath = predecessor;
      artifacts = [ { role = outputRole; path = outputPath; } ] ++ phaseArtifacts ++ lib.optionals (phase == "validate") [
        { role = "bitstream-drc-report"; path = "${reportDirectory}/shell_drc_bitstream_checks${reportSuffix}.rpt"; }
        { role = "validation-result"; path = "${reportDirectory}/validation.json"; }
      ];
      outcome = if phase == "validate" then "accepted" else "complete";
      outcomePath = if phase == "validate" then "${reportDirectory}/validation.json" else null;
      telemetryPhysicalPath = physicalPath;
    };
    in mkStage {
      pname = "${pname}-${name}-${phase}";
      board = boardProfile;
      inherit xilinxVersion;
      cores = checkedImplementationCores;
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
        ${importImplementationStageArtifacts {
          previousStage = predecessor;
          roles = [ predecessorRole ];
          expectedPhase = predecessorPhase;
          expectedContext = implementationContext.id;
        }}
        ${extraPreBuildSetup}
      '';
      buildCommands = [ "make physical_stage" ];
      expectedPaths = [ outputPath "checkpoints/${name}_${phase}_complete" physicalPath ]
        ++ map (artifact: artifact.path) phaseArtifacts
        ++ lib.optionals (phase == "validate") [
          "${reportDirectory}/shell_drc_bitstream_checks${reportSuffix}.rpt"
          "${reportDirectory}/validation.json"
        ];
      nativeBuildInputs = [ pkgs.jq pkgs.python3 ];
      extraInstallPhase = ''
        mkdir -p "$out/$(dirname ${outputPath})" "$out/metadata" "$out/${reportDirectory}"
        cp "$build_dir/${outputPath}" "$out/${outputPath}"
        cp "$build_dir/${reportDirectory}/"*.rpt "$out/${reportDirectory}/"
        cp "$build_dir/${physicalPath}" "$out/${physicalPath}"
        ${lib.optionalString (phase == "place" && boardProfile.board == "v80") ''
          cp "$build_dir/${reportDirectory}/${reportPrefix}_diagnosis${reportSuffix}.json" "$out/${reportDirectory}/"
        ''}
        ${lib.optionalString (phase == "validate") ''
          cp "$build_dir/${reportDirectory}/validation.json" "$out/${reportDirectory}/"
        ''}
        ${lib.optionalString incrementalEvidence ''
          cp "$build_dir/metadata/incremental-reference.json" "$out/metadata/incremental-reference.json"
        ''}
        ${writeImplementationStageManifest { inherit spec; }}
      '';
    };

  outerOpt = if outerLink == null then null else mkPhysicalStage {
    name = "shell"; unit = "shell"; phase = "opt";
    predecessor = outerLink; predecessorPhase = "link"; predecessorRole = "linked-checkpoint";
    inputPath = "checkpoints/shell_linked.dcp"; outputPath = "checkpoints/shell_opted.dcp"; outputRole = "optimized-checkpoint";
    strategy.opt = implementationDirectives.opt;
    extraFlags = [ "-DIMPLEMENTATION_OPT_DIRECTIVE:STRING=${implementationDirectives.opt}" ];
  };
  outerPlace = if outerOpt == null then null else mkPhysicalStage {
    name = "shell"; unit = "shell"; phase = "place";
    predecessor = outerOpt; predecessorPhase = "opt"; predecessorRole = "optimized-checkpoint";
    inputPath = "checkpoints/shell_opted.dcp"; outputPath = "checkpoints/shell_phys_opted.dcp"; outputRole = "placed-checkpoint";
    strategy = { place = implementationDirectives.place; physOpt = implementationDirectives.physOpt; };
    extraFlags = [ "-DIMPLEMENTATION_PLACE_DIRECTIVE:STRING=${implementationDirectives.place}" "-DIMPLEMENTATION_PHYS_OPT_DIRECTIVE:STRING=${implementationDirectives.physOpt}" ];
  };
  outerRoute = if outerPlace == null then null else mkPhysicalStage {
    name = "shell"; unit = "shell"; phase = "route";
    predecessor = outerPlace; predecessorPhase = "place"; predecessorRole = "placed-checkpoint";
    inputPath = "checkpoints/shell_phys_opted.dcp"; outputPath = "checkpoints/shell_routed_unvalidated.dcp"; outputRole = "routed-checkpoint";
    strategy = { route = implementationDirectives.route; postRoutePhysOpt = implementationDirectives.postRoutePhysOpt; finalRoute = implementationDirectives.finalRoute; };
    extraFlags = [ "-DIMPLEMENTATION_ROUTE_DIRECTIVE:STRING=${implementationDirectives.route}" "-DIMPLEMENTATION_POST_ROUTE_PHYS_OPT_DIRECTIVE:STRING=${implementationDirectives.postRoutePhysOpt}" "-DIMPLEMENTATION_FINAL_ROUTE_DIRECTIVE:STRING=${implementationDirectives.finalRoute}" ];
  };
  outerValidate = if outerRoute == null then null else mkPhysicalStage {
    name = "shell"; unit = "shell"; phase = "validate";
    predecessor = outerRoute; predecessorPhase = "route"; predecessorRole = "routed-checkpoint";
    inputPath = "checkpoints/shell_routed_unvalidated.dcp"; outputPath = "checkpoints/shell_routed.dcp"; outputRole = "validated-checkpoint";
    strategy.enforceTiming = if checkedImplementationEnforceTiming == null then "project" else checkedImplementationEnforceTiming;
    extraFlags = [
      "-DIMPLEMENTATION_ENFORCE_TIMING:STRING=${if checkedImplementationEnforceTiming == null then "project" else if checkedImplementationEnforceTiming then "1" else "0"}"
      "-DIMPLEMENTATION_REPORT_DIR:PATH=$build_dir/reports"
      "-DIMPLEMENTATION_LABEL:STRING=routed_shell"
      "-DIMPLEMENTATION_DRC_NAME:STRING=shell_bitstream_gate"
    ];
  };
  outerValidationGate = if outerValidate == null then null else mkImplementationStageGate {
    pname = "${pname}-shell-validation-gate";
    stage = outerValidate;
    expectedContext = implementationContext.id;
  };
  routed = outerValidationGate;

  dynamicInputs = mkInputBundle {
    name = "config_0";
    artifacts = (lib.optionals (outerValidate != null) [ { role = "outer-validated-checkpoint"; path = "checkpoints/shell_routed.dcp"; } ]) ++ [
      { role = "shell-synthesized-checkpoint"; path = "checkpoints/shell/shell_synthed.dcp"; }
      { role = "seed-synthesized-checkpoint"; path = "checkpoints/config_0/user_synthed_c0_0.dcp"; }
    ] ++ lib.optionals (boardProfile.fpgaArchitecture == "versal") [
      { role = "static-synthesized-checkpoint"; path = "checkpoints/static_synthed_${boardProfile.platform}_gen${toString implementationPcieGeneration}.dcp"; }
    ];
    commands = ''
      ${lib.optionalString (outerValidate != null) ''
        test -e ${outerValidationGate}/metadata/outcome
        cp ${outerValidate}/checkpoints/shell_routed.dcp "$out/checkpoints/"
      ''}
      cp ${synth}/checkpoints/shell/shell_synthed.dcp "$out/checkpoints/shell/"
      cp ${synth}/checkpoints/config_0/user_synthed_c0_0.dcp "$out/checkpoints/config_0/"
      ${lib.optionalString (boardProfile.fpgaArchitecture == "versal") ''
        cp ${staticPath}/static_synthed_${boardProfile.platform}_gen${toString implementationPcieGeneration}.dcp \
          "$out/checkpoints/static_synthed_${boardProfile.platform}_gen${toString implementationPcieGeneration}.dcp"
      ''}
    '';
  };
  dynamicLinkSpec = mkImplementationSpec {
    name = "config-0-link"; phase = "link"; unit = "config_0"; predecessorPath = dynamicInputs;
    artifacts = [ { role = "linked-checkpoint"; path = "checkpoints/config_0/shell_linked_c0.dcp"; } ];
  };
  dynamicLink = mkStage {
    pname = "${pname}-config-0-link";
    board = boardProfile; inherit xilinxVersion; cores = checkedImplementationCores;
    cmakeFlags = shellImplementationBaseFlags ++ lib.optionals (boardProfile.fpgaArchitecture == "versal") [ "-DSTATIC_PATH=${dynamicInputs}/checkpoints" ];
    preBuildSetup = ''
      ${lib.optionalString (boardProfile.fpgaArchitecture == "versal") timingGateDependency}
      ${importImplementationStageArtifacts {
        previousStage = dynamicInputs;
        roles = [ "shell-synthesized-checkpoint" "seed-synthesized-checkpoint" ] ++ lib.optionals (outerValidate != null) [ "outer-validated-checkpoint" ];
        expectedPhase = "inputs"; expectedContext = implementationContext.id;
      }}
    '';
    buildCommands = [ "make dynamic_link" ];
    expectedPaths = [ "checkpoints/dynamic_link_complete" "checkpoints/config_0/shell_linked_c0.dcp" ];
    nativeBuildInputs = [ pkgs.python3 ];
    extraInstallPhase = ''
      mkdir -p "$out/checkpoints/config_0" "$out/metadata"
      cp "$build_dir/checkpoints/config_0/shell_linked_c0.dcp" "$out/checkpoints/config_0/"
      ${writeImplementationStageManifest { spec = dynamicLinkSpec; }}
    '';
  };
  dynamicOpt = mkPhysicalStage {
    name = "config_0"; unit = "config_0"; phase = "opt";
    predecessor = dynamicLink; predecessorPhase = "link"; predecessorRole = "linked-checkpoint";
    inputPath = "checkpoints/config_0/shell_linked_c0.dcp"; outputPath = "checkpoints/config_0/shell_opted_c0.dcp"; outputRole = "optimized-checkpoint";
    strategy.opt = implementationDirectives.opt;
    extraFlags = [ "-DIMPLEMENTATION_OPT_DIRECTIVE:STRING=${implementationDirectives.opt}" ];
  };
  dynamicPlace = mkPhysicalStage {
    name = "config_0"; unit = "config_0"; phase = "place";
    predecessor = dynamicOpt; predecessorPhase = "opt"; predecessorRole = "optimized-checkpoint";
    inputPath = "checkpoints/config_0/shell_opted_c0.dcp"; outputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp"; outputRole = "placed-checkpoint";
    strategy = { place = implementationDirectives.place; physOpt = implementationDirectives.physOpt; };
    extraFlags = [ "-DIMPLEMENTATION_PLACE_DIRECTIVE:STRING=${implementationDirectives.place}" "-DIMPLEMENTATION_PHYS_OPT_DIRECTIVE:STRING=${implementationDirectives.physOpt}" ];
  };
  dynamicRoute = mkPhysicalStage {
    name = "config_0"; unit = "config_0"; phase = "route";
    predecessor = dynamicPlace; predecessorPhase = "place"; predecessorRole = "placed-checkpoint";
    inputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp"; outputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp"; outputRole = "routed-checkpoint";
    strategy = { route = implementationDirectives.route; postRoutePhysOpt = implementationDirectives.postRoutePhysOpt; finalRoute = implementationDirectives.finalRoute; };
    extraFlags = [ "-DIMPLEMENTATION_ROUTE_DIRECTIVE:STRING=${implementationDirectives.route}" "-DIMPLEMENTATION_POST_ROUTE_PHYS_OPT_DIRECTIVE:STRING=${implementationDirectives.postRoutePhysOpt}" "-DIMPLEMENTATION_FINAL_ROUTE_DIRECTIVE:STRING=${implementationDirectives.finalRoute}" ];
  };
  incrementalReferenceSetup = reference: ''
    mkdir -p "$build_dir/metadata" "$build_dir/checkpoints/config_0"
    ${pkgs.python3}/bin/python ${incrementalReferenceTool} \
      ${implementationStageTool} ${reference} ${implementationContextFile} \
      "$build_dir/metadata/incremental-reference.json"
    reference_relative="$(${pkgs.jq}/bin/jq -r '.reference.checkpoint.path' \
      "$build_dir/metadata/incremental-reference.json")"
    reference_sha256="$(${pkgs.jq}/bin/jq -r '.reference.checkpoint.sha256' \
      "$build_dir/metadata/incremental-reference.json")"
    cp "${reference}/$reference_relative" \
      "$build_dir/checkpoints/config_0/incremental_reference.dcp"
    test "$(sha256sum "$build_dir/checkpoints/config_0/incremental_reference.dcp" | cut -d ' ' -f 1)" = \
      "$reference_sha256"
  '';
  incrementalOpt = if checkedIncrementalReference == null then null else mkPhysicalStage {
    name = "config_0_incremental"; unit = "config_0"; phase = "opt";
    predecessor = dynamicLink; predecessorPhase = "link"; predecessorRole = "linked-checkpoint";
    inputPath = "checkpoints/config_0/shell_linked_c0.dcp";
    outputPath = "checkpoints/config_0/shell_opted_c0.dcp"; outputRole = "optimized-checkpoint";
    incrementalMode = "reference"; incrementalEvidence = true;
    extraPreBuildSetup = incrementalReferenceSetup checkedIncrementalReference;
    strategy = {
      opt = implementationDirectives.opt;
      incremental = { mode = "explicit-reference"; referencePath = toString checkedIncrementalReference; signoffAuthority = false; };
    };
    extraFlags = [
      "-DIMPLEMENTATION_OPT_DIRECTIVE:STRING=${implementationDirectives.opt}"
      "-DIMPLEMENTATION_INCREMENTAL_REFERENCE_DCP:FILEPATH=$build_dir/checkpoints/config_0/incremental_reference.dcp"
    ];
  };
  incrementalPlace = if incrementalOpt == null then null else mkPhysicalStage {
    name = "config_0_incremental"; unit = "config_0"; phase = "place";
    predecessor = incrementalOpt; predecessorPhase = "opt"; predecessorRole = "optimized-checkpoint";
    inputPath = "checkpoints/config_0/shell_opted_c0.dcp";
    outputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp"; outputRole = "placed-checkpoint";
    incrementalMode = "reference";
    strategy = { place = implementationDirectives.place; physOpt = implementationDirectives.physOpt; incremental.mode = "explicit-reference"; };
    extraFlags = [ "-DIMPLEMENTATION_PLACE_DIRECTIVE:STRING=${implementationDirectives.place}" "-DIMPLEMENTATION_PHYS_OPT_DIRECTIVE:STRING=${implementationDirectives.physOpt}" ];
  };
  incrementalRoute = if incrementalPlace == null then null else mkPhysicalStage {
    name = "config_0_incremental"; unit = "config_0"; phase = "route";
    predecessor = incrementalPlace; predecessorPhase = "place"; predecessorRole = "placed-checkpoint";
    inputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
    outputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp"; outputRole = "routed-checkpoint";
    incrementalMode = "reference";
    strategy = {
      route = implementationDirectives.route;
      postRoutePhysOpt = implementationDirectives.postRoutePhysOpt;
      finalRoute = implementationDirectives.finalRoute;
      incremental.mode = "explicit-reference";
    };
    extraFlags = [ "-DIMPLEMENTATION_ROUTE_DIRECTIVE:STRING=${implementationDirectives.route}" "-DIMPLEMENTATION_POST_ROUTE_PHYS_OPT_DIRECTIVE:STRING=${implementationDirectives.postRoutePhysOpt}" "-DIMPLEMENTATION_FINAL_ROUTE_DIRECTIVE:STRING=${implementationDirectives.finalRoute}" ];
  };
  incrementalValidate = if incrementalRoute == null then null else mkPhysicalStage {
    name = "config_0_incremental"; unit = "config_0"; phase = "validate";
    predecessor = incrementalRoute; predecessorPhase = "route"; predecessorRole = "routed-checkpoint";
    inputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
    outputPath = "checkpoints/config_0/shell_routed_c0.dcp"; outputRole = "validated-checkpoint";
    incrementalMode = "reference";
    strategy = { incremental.mode = "explicit-reference"; enforceTiming = if checkedImplementationEnforceTiming == null then "project" else checkedImplementationEnforceTiming; };
    extraFlags = [
      "-DIMPLEMENTATION_ENFORCE_TIMING:STRING=${if checkedImplementationEnforceTiming == null then "project" else if checkedImplementationEnforceTiming then "1" else "0"}"
      "-DIMPLEMENTATION_LABEL:STRING=config_0_incremental_routed_shell"
      "-DIMPLEMENTATION_DRC_NAME:STRING=config_0_incremental_bitstream_gate"
    ];
  };
  incrementalGate = if incrementalValidate == null then null else mkImplementationStageGate {
    pname = "${pname}-incremental-validation-gate";
    stage = incrementalValidate;
    expectedContext = implementationContext.id;
  };

  dynamicValidateSpec = mkImplementationSpec {
    name = "config-0-validate"; phase = "validate"; unit = "config_0"; predecessorPath = dynamicRoute;
    strategy.enforceTiming = if checkedImplementationEnforceTiming == null then "project" else checkedImplementationEnforceTiming;
    outcome = "accepted";
    outcomePath = "reports/config_0/validation.json";
    telemetryPhysicalPath = "reports/config_0/shell_physical_c0.json";
    artifacts = [
      { role = "validated-checkpoint"; path = "checkpoints/config_0/shell_routed_c0.dcp"; }
      { role = "utilization-report"; path = "reports/config_0/shell_utilization_c0.rpt"; }
      { role = "route-status-report"; path = "reports/config_0/shell_route_status_c0.rpt"; }
      { role = "timing-summary-report"; path = "reports/config_0/shell_timing_summary_c0.rpt"; }
      { role = "bitstream-drc-report"; path = "reports/config_0/shell_drc_bitstream_checks_c0.rpt"; }
      { role = "validation-result"; path = "reports/config_0/validation.json"; }
    ];
  };
  dynamicValidationRaw = mkStage {
    pname = "${pname}-dynamic-validation";
    board = boardProfile; inherit xilinxVersion; cores = checkedImplementationCores;
    checkTimingLog = false;
    cmakeFlags = shellImplementationBaseFlags ++ [
      "-DIMPLEMENTATION_PHASE:STRING=validate"
      "-DIMPLEMENTATION_INPUT_DCP:FILEPATH=$build_dir/checkpoints/config_0/shell_routed_unvalidated_c0.dcp"
      "-DIMPLEMENTATION_OUTPUT_DCP:FILEPATH=$build_dir/checkpoints/config_0/shell_routed_c0.dcp"
      "-DIMPLEMENTATION_COMPLETION_PATH:FILEPATH=$build_dir/checkpoints/config_0/validate_complete"
      "-DIMPLEMENTATION_REPORT_DIR:PATH=$build_dir/reports/config_0"
      "-DIMPLEMENTATION_REPORT_SUFFIX:STRING=_c0"
      "-DIMPLEMENTATION_LABEL:STRING=config_0_routed_shell"
      "-DIMPLEMENTATION_DRC_NAME:STRING=config_0_bitstream_gate"
      "-DIMPLEMENTATION_VALIDATION_SUMMARY:FILEPATH=$build_dir/reports/config_0/validation.json"
      "-DIMPLEMENTATION_TELEMETRY_PATH:FILEPATH=$build_dir/reports/config_0/shell_physical_c0.json"
      "-DIMPLEMENTATION_ENFORCE_TIMING:STRING=${if checkedImplementationEnforceTiming == null then "project" else if checkedImplementationEnforceTiming then "1" else "0"}"
    ];
    preBuildSetup = importImplementationStageArtifacts {
      previousStage = dynamicRoute; roles = [ "routed-checkpoint" ]; expectedPhase = "route"; expectedContext = implementationContext.id;
    };
    buildCommands = [ "make physical_stage" ];
    expectedPaths = [
      "checkpoints/config_0/shell_routed_c0.dcp"
      "reports/config_0/shell_physical_c0.json"
      "reports/config_0/validation.json"
    ];
    nativeBuildInputs = [ pkgs.python3 ];
    extraInstallPhase = ''
      mkdir -p "$out/checkpoints/config_0" "$out/reports/config_0" "$out/metadata"
      cp "$build_dir/checkpoints/config_0/shell_routed_c0.dcp" "$out/checkpoints/config_0/"
      cp -a "$build_dir/reports/config_0/." "$out/reports/config_0/"
      ${writeImplementationStageManifest { spec = dynamicValidateSpec; }}
    '';
  };

  dynamicValidationGate = mkImplementationStageGate {
    pname = "${pname}-dynamic-validation-gate";
    stage = dynamicValidationRaw;
    expectedContext = implementationContext.id;
  };
  dynamicFinalizeSpec = mkImplementationSpec {
    name = "config-0-finalize"; phase = "finalize"; unit = "config_0"; predecessorPath = dynamicValidationRaw;
    outcome = "accepted";
    artifacts = [
      { role = "validated-checkpoint"; path = "checkpoints/config_0/shell_routed_c0.dcp"; }
      { role = "locked-shell-checkpoint"; path = "checkpoints/shell_routed_locked.dcp"; }
      { role = "utilization-report"; path = "reports/config_0/shell_utilization_c0.rpt"; }
      { role = "route-status-report"; path = "reports/config_0/shell_route_status_c0.rpt"; }
      { role = "timing-summary-report"; path = "reports/config_0/shell_timing_summary_c0.rpt"; }
      { role = "bitstream-drc-report"; path = "reports/config_0/shell_drc_bitstream_checks_c0.rpt"; }
      { role = "validation-result"; path = "reports/config_0/validation.json"; }
    ] ++ lib.optionals (boardProfile.fpgaArchitecture == "ultrascale_plus") [ { role = "recombined-checkpoint"; path = "checkpoints/shell_recombined.dcp"; } ]
      ++ lib.optionals (boardProfile.fpgaArchitecture == "versal") [ { role = "root-routed-checkpoint"; path = "checkpoints/shell_routed.dcp"; } ];
  };
  dynamic = mkStage {
    pname = "${pname}-dynamic";
    board = boardProfile; inherit xilinxVersion; cores = checkedImplementationCores;
    checkTimingLog = false;
    cmakeFlags = shellImplementationBaseFlags ++ [ "-DIMPLEMENTATION_PHASE:STRING=finalize" ];
    preBuildSetup = ''
      test -e ${dynamicValidationGate}/metadata/outcome
      ${importImplementationStageArtifacts {
        previousStage = dynamicValidationRaw;
        expectedPhase = "validate";
        expectedContext = implementationContext.id;
      }}
    '';
    buildCommands = [ "make dynamic_finalize" ];
    expectedPaths = [
      "checkpoints/config_0/shell_routed_c0.dcp"
      "checkpoints/shell_routed_locked.dcp"
      "checkpoints/dynamic_finalize_complete"
    ] ++ lib.optionals (boardProfile.fpgaArchitecture == "ultrascale_plus") [ "checkpoints/shell_recombined.dcp" ]
      ++ lib.optionals (boardProfile.fpgaArchitecture == "versal") [ "checkpoints/shell_routed.dcp" ];
    nativeBuildInputs = [ pkgs.python3 ];
    extraInstallPhase = ''
      mkdir -p "$out/checkpoints/config_0" "$out/reports/config_0" "$out/metadata"
      cp "$build_dir/checkpoints/config_0/shell_routed_c0.dcp" "$out/checkpoints/config_0/"
      cp "$build_dir/checkpoints/shell_routed_locked.dcp" "$out/checkpoints/"
      cp -a "$build_dir/reports/config_0/." "$out/reports/config_0/"
      ${lib.optionalString (boardProfile.fpgaArchitecture == "ultrascale_plus") ''cp "$build_dir/checkpoints/shell_recombined.dcp" "$out/checkpoints/"''}
      ${lib.optionalString (boardProfile.fpgaArchitecture == "versal") ''cp "$build_dir/checkpoints/shell_routed.dcp" "$out/checkpoints/"''}
      ${writeImplementationStageManifest { spec = dynamicFinalizeSpec; }}
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
    staticPath = toString staticPath;
    inherit shellCmakeFlags shellSynthesisCmakeFlags;
    synthesisAnalysis = {
      policy = synthesisAnalysisPolicy;
      raw = synthesisAnalysisRaw;
      stage = synthesisAnalysisStage;
      gate = synthesisAnalysisGate;
      metadata = "metadata/synthesis-analysis.json";
      classification = "metadata/classification";
    };
    timingOracle = {
      policy = timingOraclePolicy;
      stage = timingOracleStage;
      gate = timingOracleGate;
      metadata = "metadata/timing-oracle.json";
      classification = "metadata/classification";
    };
    physical = {
      api = "coyote-nix.implementation-stage/v2";
      context = implementationContext;
      resources.cores = checkedImplementationCores;
      directives = implementationDirectives;
      image = "self";
      incremental = if checkedIncrementalReference == null then null else {
        api = "coyote-nix.incremental-implementation/v1";
        experimental = true;
        signoffAuthority = false;
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
          validate = dynamicValidationRaw;
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
    };
  };

  imageSpec = mkImplementationSpec {
    name = "image";
    phase = "image";
    unit = "config_0";
    predecessorPath = dynamic;
    strategy = { };
    outcome = "accepted";
    artifacts = (map (artifact: {
      role = "image-${builtins.replaceStrings [ "/" "." ] [ "-" "-" ] artifact}";
      path = "bitstreams/${artifact}";
    }) shellExpectedBitstreams) ++ [
      { role = "primary-tool-invocation"; path = "metadata/primary-tool.json"; }
    ];
  };

  final = mkStage {
    inherit pname xilinxVersion;
    board = boardProfile;
    cores = checkedImplementationCores;
    cmakeFlags = shellCmakeFlags;
    preBuildSetup = ''
      test -e ${dynamicValidationGate}/metadata/outcome
      ${importImplementationStageArtifacts {
        previousStage = dynamic;
        expectedPhase = "finalize";
        expectedContext = implementationContext.id;
      }}
    '';
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
      ${writeImplementationStageManifest { spec = imageSpec; }}
    '';
    extraAttrs = {
      passthru.coyoteTwoStage = contract // {
        stages = {
          inherit synth dynamic;
          implementationInputs = dynamicInputs;
          link = dynamicLink;
          opt = dynamicOpt;
          place = dynamicPlace;
          route = dynamicRoute;
          validate = dynamicValidationRaw;
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
final
