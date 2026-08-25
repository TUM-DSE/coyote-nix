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
    installCheckpointReports
    mkStage
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

  routed =
    if boardProfile.fpgaArchitecture == "ultrascale_plus" then
      mkStage {
        pname = "${pname}-routed";
        board = boardProfile;
        inherit xilinxVersion;
        cmakeFlags = shellCmakeFlags;
        preBuildSetup = ''
          ${timingGateDependency}
          ${copyPreviousStageSetup synth { }}
        '';
        buildCommands = [
          "make project"
          "make shell"
        ];
        expectedPaths = [
          "checkpoints/shell_linked.dcp"
          "checkpoints/shell_routed.dcp"
        ];
        extraInstallPhase = installCheckpointReports {
          copyAllCheckpoints = true;
          copyAllReports = true;
        };
        description = "Coyote ${boardProfile.platform} PR shell routed stage";
      }
    else
      null;

  preDynamicStage = if routed == null then synth else routed;

  dynamic = mkStage {
    pname = "${pname}-dynamic";
    board = boardProfile;
    inherit xilinxVersion;
    cmakeFlags = shellCmakeFlags;
    preBuildSetup = ''
      ${lib.optionalString (boardProfile.fpgaArchitecture == "versal") timingGateDependency}
      ${copyPreviousStageSetup preDynamicStage { }}
    '';
    buildCommands = [
      "make project"
      "make app"
    ];
    expectedPaths = [
      "checkpoints/shell_routed_locked.dcp"
      "checkpoints/config_0/shell_routed_c0.dcp"
    ]
    ++ lib.optionals (boardProfile.fpgaArchitecture == "ultrascale_plus") [
      "checkpoints/shell_subdivided.dcp"
      "checkpoints/shell_recombined.dcp"
    ]
    ++ lib.optionals (boardProfile.fpgaArchitecture == "versal") [
      "checkpoints/shell_routed.dcp"
    ];
    extraInstallPhase = installCheckpointReports {
      copyAllCheckpoints = true;
      copyAllReports = true;
    };
    description = "Coyote ${boardProfile.platform} PR shell dynamic implementation stage";
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
  };

  final = mkStage {
    inherit pname xilinxVersion;
    board = boardProfile;
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
    extraInstallPhase = installShellExport;
    extraAttrs = {
      passthru.coyoteTwoStage = contract // {
        stages = {
          inherit synth dynamic;
          timingOracle = timingOracleStage;
          timingGate = timingOracleGate;
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
