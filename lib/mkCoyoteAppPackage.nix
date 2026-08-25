{
  pkgs,
  tools,
  coyoteRoot,
  hwSource,
  xilinxShareRoot,
  xilinxShell ? null,
  pname,
  version ? "0.1.0",
  shellPackage,
  board ? null,
  cmakeFlags ? [ ],
  provenance ? { },
  implementation ? { },
}:

let
  lib = pkgs.lib;
  shellContract =
    if shellPackage ? coyoteTwoStage then
      shellPackage.coyoteTwoStage
    else
      throw "coyote-nix: mkCoyoteAppPackage requires a shell from mkCoyoteShellPackage";
  checkedShellContract =
    if (shellContract.kind or null) == "shell" && (shellContract.enPr or false) then
      shellContract
    else
      throw "coyote-nix: mkCoyoteAppPackage requires an EN_PR shell contract";
  boardName =
    if board == null then
      checkedShellContract.board
    else if board == checkedShellContract.board then
      board
    else
      throw "coyote-nix: requested app board ${board} does not match shell board ${checkedShellContract.board}";

  boardProfiles = import ./coyoteBoardProfiles.nix;
  boardProfile =
    boardProfiles.${boardName}
      or (throw "coyote-nix: mkCoyoteAppPackage supports only u280 and v80, not ${boardName}");
  xilinxVersion = checkedShellContract.xilinxVersion;

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
    importImplementationStageArtifacts
    installCheckpointReports
    mkImplementationStageGate
    mkStage
    writeArtifactManifest
    writeImplementationStageManifest
    ;

  enShellPblock = if boardProfile.twoStage.enShellPblock then "1" else "0";
  appCmakeFlags = cmakeFlags ++ [
    "-DFDEV_NAME:STRING=${boardProfile.platform}"
    "-DBUILD_APP:STRING=1"
    "-DBUILD_STATIC:STRING=0"
    "-DBUILD_SHELL:STRING=0"
    "-DEN_PR:STRING=1"
    "-DEN_SHELL_PBLOCK:STRING=${enShellPblock}"
    "-DSHELL_PATH=${shellPackage}"
  ];

  appExpectedBitstreams = boardProfile.twoStage.appExpectedBitstreams;
  isImplementationPolicyFlag = flag:
    builtins.match "^-DSHELL_PATH(:[^=]+)?=.*$" flag != null;
  appImplementationBaseFlags = builtins.filter (flag: !isImplementationPolicyFlag flag) appCmakeFlags ++ [
    "-DIMMUTABLE_IMPLEMENTATION_STAGES:BOOL=ON"
  ];
  implementationEnforceTiming = implementation.enforceTiming or null;
  checkedImplementationEnforceTiming =
    if implementationEnforceTiming == null || builtins.isBool implementationEnforceTiming then
      implementationEnforceTiming
    else
      throw "coyote-nix: implementation.enforceTiming must be a Boolean when specified";
  effectiveFlagValue = name: flags:
    let matches = builtins.filter (entry: entry != null) (map (flag:
      builtins.match "^-D${name}(:[^=]+)?=(.*)$" flag) flags);
    in if matches == [ ] then null else builtins.elemAt (lib.last matches) 1;
  flagIsTrue = value: builtins.elem value [ "1" "ON" "TRUE" "YES" ];
  optimizedCompatibility = flagIsTrue (effectiveFlagValue "BUILD_OPT" cmakeFlags);
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
  checkedImplementationCores =
    if builtins.isInt implementationCores && implementationCores > 0 then
      implementationCores
    else
      throw "coyote-nix: implementation.resources.cores must be a positive integer";
  implementationContextWithoutId = {
    board = boardProfile.board;
    architecture = boardProfile.fpgaArchitecture;
    part = boardProfile.fpgaPart;
    flow = "build-app";
    topology = checkedImplementationTopology;
    sourceId = builtins.hashString "sha256" (toString hwSource);
    coyoteSourceId = builtins.hashString "sha256" (toString coyoteRoot);
    constraintsId = builtins.hashString "sha256" (builtins.toJSON {
      source = toString hwSource;
      flags = appImplementationBaseFlags;
    });
    toolId = implementation.xilinxInstallationId or "vivado-${xilinxVersion}@${toString xilinxShareRoot}";
    toolVersion = xilinxVersion;
  };
  implementationContext = implementationContextWithoutId // {
    id = builtins.hashString "sha256" (builtins.toJSON implementationContextWithoutId);
  };
  implementationContextJson = builtins.toJSON implementationContext;
  mkImplementationSpec =
    {
      name,
      phase,
      artifactRole ? null,
      artifactPath ? null,
      artifacts ? null,
      predecessorPath ? null,
      strategy ? { },
      outcome ? "complete",
      outcomePath ? null,
      telemetryPhysicalPath ? null,
    }:
    let
      declaredArtifacts = if artifacts != null then artifacts else [ { role = artifactRole; path = artifactPath; } ];
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
      inherit phase outcome strategy;
      unit = "config_0";
      context = implementationContext;
      resources.cores = checkedImplementationCores;
      artifacts = declaredArtifacts ++ telemetryArtifacts;
      predecessorPath = if predecessorPath == null then null else toString predecessorPath;
      outcomePath = outcomePath;
      telemetry = if phase == "inputs" then null else {
        path = "metadata/telemetry.json";
        executionPath = "metadata/execution.json";
        physicalPath = telemetryPhysicalPath;
      };
    });
  validateShellPackage = ''
    if [ ! -f ${shellPackage}/export.cmake ]; then
      echo "ERROR: shell package does not contain export.cmake: ${shellPackage}" >&2
      exit 1
    fi
    if [ ! -f ${shellPackage}/checkpoints/shell_routed_locked.dcp ]; then
      echo "ERROR: shell package does not contain shell_routed_locked.dcp: ${shellPackage}" >&2
      exit 1
    fi
    if [ ! -f ${shellPackage}/metadata/shell.json ] || [ ! -f ${shellPackage}/metadata/compatibility-id ]; then
      echo "ERROR: shell package does not contain coyote-nix compatibility metadata: ${shellPackage}" >&2
      exit 1
    fi

    jq -e \
      --arg board '${boardProfile.board}' \
      --arg architecture '${boardProfile.fpgaArchitecture}' \
      --arg xilinxVersion '${xilinxVersion}' \
      '.kind == "coyote-shell"
       and .board == $board
       and .fpgaArchitecture == $architecture
       and .xilinxVersion == $xilinxVersion
       and .flow.enPr == true' \
      ${shellPackage}/metadata/shell.json >/dev/null

    expected_export_sha256="$(jq -r '.compatibility.exportCmakeSha256' ${shellPackage}/metadata/shell.json)"
    actual_export_sha256="$(sha256sum ${shellPackage}/export.cmake | cut -d ' ' -f 1)"
    expected_locked_sha256="$(jq -r '.compatibility.shellRoutedLockedDcpSha256' ${shellPackage}/metadata/shell.json)"
    actual_locked_sha256="$(sha256sum ${shellPackage}/checkpoints/shell_routed_locked.dcp | cut -d ' ' -f 1)"
    expected_compatibility_id="$(jq -r '.compatibility.id' ${shellPackage}/metadata/shell.json)"
    actual_compatibility_id="$(tr -d '\n' < ${shellPackage}/metadata/compatibility-id)"

    if [ "$expected_export_sha256" != "$actual_export_sha256" ] \
      || [ "$expected_locked_sha256" != "$actual_locked_sha256" ] \
      || [ "$expected_compatibility_id" != "$actual_compatibility_id" ]; then
      echo "ERROR: shell compatibility metadata does not match packaged shell artifacts" >&2
      exit 1
    fi
  '';

  appMetadataBase = pkgs.writeText "${pname}-app-metadata-base.json" (
    builtins.toJSON {
      schemaVersion = 1;
      api = "coyote-nix.two-stage/v1";
      kind = "coyote-app";
      inherit version xilinxVersion;
      board = boardProfile.board;
      platform = boardProfile.platform;
      coyotePlatform = boardProfile.coyotePlatform;
      fpgaArchitecture = boardProfile.fpgaArchitecture;
      fpgaPart = boardProfile.fpgaPart;
      flow = {
        buildStatic = false;
        buildShell = false;
        buildApp = true;
        enPr = true;
        enShellPblock = boardProfile.twoStage.enShellPblock;
        stages = [
          "synth"
          "app-route"
          "bitgen"
        ];
      };
      shell = {
        package = toString shellPackage;
        metadata = "metadata/shell.json";
      };
      provenance = {
        coyoteSource = toString coyoteRoot;
        hardwareSource = toString hwSource;
        shellCoyoteSource = checkedShellContract.coyoteSource;
        coyoteSourceMatchesShell = toString coyoteRoot == checkedShellContract.coyoteSource;
        caller = provenance;
      };
    }
  );

  installAppExport = ''
    mkdir -p "$out/checkpoints" "$out/reports" "$out/bitstreams" "$out/metadata"

    cp -r "$build_dir/checkpoints/." "$out/checkpoints/"
    if [ -d "$build_dir/reports" ]; then
      cp -r "$build_dir/reports/." "$out/reports/"
    fi

    found_config=0
    for config_dir in "$build_dir"/bitstreams/config_*; do
      if [ -d "$config_dir" ]; then
        cp -r "$config_dir" "$out/bitstreams/"
        found_config=1
      fi
    done
    if [ "$found_config" -ne 1 ]; then
      echo "ERROR: BUILD_APP did not produce any config_* partial-artifact directory" >&2
      exit 1
    fi
    if find "$out/bitstreams" -mindepth 1 -maxdepth 1 ! -name 'config_*' | grep -q .; then
      echo "ERROR: app package contains a non-app bitstream artifact" >&2
      exit 1
    fi

    cp ${implementationInputs}/metadata/shell.json "$out/metadata/shell.json"
    cp ${implementationInputs}/metadata/compatibility-id "$out/metadata/shell-compatibility-id"

    ${writeArtifactManifest {
      roots = [
        "$out/checkpoints"
        "$out/reports"
        "$out/bitstreams"
      ];
      output = "$out/metadata/artifacts.json";
    }}

    shell_compatibility_id="$(tr -d '\n' < "$out/metadata/shell-compatibility-id")"
    shell_export_sha256="$(jq -r '.compatibility.exportCmakeSha256' "$out/metadata/shell.json")"
    shell_locked_dcp_sha256="$(jq -r '.compatibility.shellRoutedLockedDcpSha256' "$out/metadata/shell.json")"
    artifact_manifest_sha256="$(jq -cS '.' "$out/metadata/artifacts.json" | sha256sum | cut -d ' ' -f 1)"
    application_id="$(
      printf '%s\0' \
        'coyote-nix-app-v1' \
        "$shell_compatibility_id" \
        "$artifact_manifest_sha256" \
        | sha256sum | cut -d ' ' -f 1
    )"

    jq \
      --arg applicationId "$application_id" \
      --arg artifactManifestSha256 "$artifact_manifest_sha256" \
      --arg shellCompatibilityId "$shell_compatibility_id" \
      --arg shellExportCmakeSha256 "$shell_export_sha256" \
      --arg shellRoutedLockedDcpSha256 "$shell_locked_dcp_sha256" \
      --slurpfile artifacts "$out/metadata/artifacts.json" \
      '.application = {
        id: $applicationId,
        artifactManifestSha256: $artifactManifestSha256
      }
      | .shell += {
        compatibilityId: $shellCompatibilityId,
        exportCmakeSha256: $shellExportCmakeSha256,
        shellRoutedLockedDcpSha256: $shellRoutedLockedDcpSha256
      }
      | .artifacts = $artifacts[0]' \
      ${appMetadataBase} > "$out/metadata/app.json"
    printf '%s\n' "$application_id" > "$out/metadata/application-id"
  '';

  stageNativeBuildInputs = [ pkgs.jq ];

  synth = mkStage {
    pname = "${pname}-synth";
    board = boardProfile;
    inherit xilinxVersion;
    cmakeFlags = appCmakeFlags;
    preBuildSetup = validateShellPackage;
    buildCommands = [
      "make project"
      "make synth"
    ];
    expectedPaths = [
      "checkpoints/config_0/user_synthed_c0_0.dcp"
    ];
    nativeBuildInputs = stageNativeBuildInputs;
    extraInstallPhase = installCheckpointReports {
      checkpointDirs = [ "config_0" ];
      reportDirs = [ "config_0" ];
    };
    description = "Coyote ${boardProfile.platform} BUILD_APP synthesis stage";
  };

  inputBundleSpec = pkgs.writeText "${pname}-implementation-inputs-spec.json" (builtins.toJSON {
    schemaVersion = 2;
    phase = "inputs";
    unit = "config_0";
    context = implementationContext;
    strategy = { };
    resources.cores = checkedImplementationCores;
    outcome = "complete";
    predecessorPath = null;
    artifacts = [
      { role = "shell-contract"; path = "export.cmake"; }
      { role = "locked-shell-checkpoint"; path = "checkpoints/shell_routed_locked.dcp"; }
      { role = "user-synthesized-checkpoint"; path = "checkpoints/config_0/user_synthed_c0_0.dcp"; }
      { role = "shell-metadata"; path = "metadata/shell.json"; }
      { role = "shell-compatibility-id"; path = "metadata/compatibility-id"; }
    ];
  });

  implementationInputs = pkgs.runCommand "${pname}-implementation-inputs"
    {
      nativeBuildInputs = [ pkgs.python3 ];
      passthru.coyoteImplementationStage = {
        api = "coyote-nix.implementation-stage/v2";
        phase = "inputs";
        context = implementationContext;
      };
    }
    ''
      mkdir -p "$out/checkpoints/config_0" "$out/metadata"
      cp ${shellPackage}/export.cmake "$out/export.cmake"
      cp ${shellPackage}/checkpoints/shell_routed_locked.dcp \
        "$out/checkpoints/shell_routed_locked.dcp"
      cp ${synth}/checkpoints/config_0/user_synthed_c0_0.dcp \
        "$out/checkpoints/config_0/user_synthed_c0_0.dcp"
      cp ${shellPackage}/metadata/shell.json "$out/metadata/shell.json"
      cp ${shellPackage}/metadata/compatibility-id "$out/metadata/compatibility-id"
      ${pkgs.python3}/bin/python ${implementationStageTool} write \
        ${inputBundleSpec} "$out" "$out"
    '';

  linkSpec = mkImplementationSpec {
    name = "link";
    phase = "link";
    artifactRole = "linked-checkpoint";
    artifactPath = "checkpoints/config_0/shell_linked_c0.dcp";
    predecessorPath = implementationInputs;
  };

  link = mkStage {
    pname = "${pname}-link";
    board = boardProfile;
    inherit xilinxVersion;
    cores = checkedImplementationCores;
    cmakeFlags = appImplementationBaseFlags ++ [ "-DSHELL_PATH=${implementationInputs}" ];
    preBuildSetup = importImplementationStageArtifacts {
      previousStage = implementationInputs;
      roles = [ "user-synthesized-checkpoint" ];
      expectedPhase = "inputs";
      expectedContext = implementationContext.id;
    };
    buildCommands = [ "make app_link" ];
    expectedPaths = [
      "checkpoints/app_link_complete"
      "checkpoints/config_0/shell_linked_c0.dcp"
    ];
    nativeBuildInputs = stageNativeBuildInputs ++ [ pkgs.python3 ];
    extraInstallPhase = ''
      mkdir -p "$out/checkpoints/config_0" "$out/metadata"
      cp "$build_dir/checkpoints/config_0/shell_linked_c0.dcp" \
        "$out/checkpoints/config_0/shell_linked_c0.dcp"
      ${writeImplementationStageManifest { spec = linkSpec; }}
    '';
    description = "Coyote ${boardProfile.platform} BUILD_APP immutable link stage";
  };

  mkPhysicalStage =
    {
      phase,
      predecessor,
      predecessorPhase,
      predecessorRole,
      inputPath,
      outputPath,
      outputRole,
      extraFlags ? [ ],
      strategy ? { },
      reports ? false,
    }:
    let
      reportPrefix = if phase == "validate" then "shell" else "shell_${phase}";
      physicalPath = "reports/config_0/${reportPrefix}_physical_c0.json";
      phaseArtifacts = [
        { role = "${phase}-utilization-report"; path = "reports/config_0/${reportPrefix}_utilization_c0.rpt"; }
        { role = "${phase}-timing-summary-report"; path = "reports/config_0/${reportPrefix}_timing_summary_c0.rpt"; }
      ] ++ lib.optionals (builtins.elem phase [ "opt" "place" ]) [
        { role = "${phase}-qor-assessment-report"; path = "reports/config_0/${reportPrefix}_qor_assessment_c0.rpt"; }
      ] ++ lib.optionals (builtins.elem phase [ "route" "validate" ]) [
        { role = "${phase}-route-status-report"; path = "reports/config_0/${reportPrefix}_route_status_c0.rpt"; }
      ];
      spec = mkImplementationSpec {
        name = phase;
        inherit phase;
        artifacts = [ { role = outputRole; path = outputPath; } ] ++ phaseArtifacts ++ lib.optionals reports [
          { role = "bitstream-drc-report"; path = "reports/config_0/shell_drc_bitstream_checks_c0.rpt"; }
          { role = "validation-result"; path = "reports/config_0/validation.json"; }
        ];
        predecessorPath = predecessor;
        inherit strategy;
        outcome = if phase == "validate" then "accepted" else "complete";
        outcomePath = if reports then "reports/config_0/validation.json" else null;
        telemetryPhysicalPath = physicalPath;
      };
    in
    mkStage {
      pname = "${pname}-${phase}";
      board = boardProfile;
      inherit xilinxVersion;
      cores = checkedImplementationCores;
      checkTimingLog = false;
      cmakeFlags = appImplementationBaseFlags ++ [
        "-DSHELL_PATH=${implementationInputs}"
        "-DIMPLEMENTATION_PHASE:STRING=${phase}"
        "-DIMPLEMENTATION_INPUT_DCP:FILEPATH=$build_dir/${inputPath}"
        "-DIMPLEMENTATION_OUTPUT_DCP:FILEPATH=$build_dir/${outputPath}"
        "-DIMPLEMENTATION_COMPLETION_PATH:FILEPATH=$build_dir/checkpoints/config_0/${phase}_complete"
        "-DIMPLEMENTATION_REPORT_DIR:PATH=$build_dir/reports/config_0"
        "-DIMPLEMENTATION_REPORT_SUFFIX:STRING=_c0"
        "-DIMPLEMENTATION_LABEL:STRING=config_0_routed_application"
        "-DIMPLEMENTATION_DRC_NAME:STRING=config_0_bitstream_gate"
        "-DIMPLEMENTATION_VALIDATION_SUMMARY:FILEPATH=$build_dir/reports/config_0/validation.json"
        "-DIMPLEMENTATION_TELEMETRY_PATH:FILEPATH=$build_dir/${physicalPath}"
      ] ++ extraFlags;
      preBuildSetup = importImplementationStageArtifacts {
        previousStage = predecessor;
        roles = [ predecessorRole ];
        expectedPhase = predecessorPhase;
        expectedContext = implementationContext.id;
      };
      buildCommands = [ "make physical_stage" ];
      expectedPaths = [
        outputPath
        "checkpoints/config_0/${phase}_complete"
        physicalPath
      ] ++ map (artifact: artifact.path) phaseArtifacts ++ lib.optionals reports [
        "reports/config_0/shell_drc_bitstream_checks_c0.rpt"
        "reports/config_0/validation.json"
      ];
      nativeBuildInputs = stageNativeBuildInputs ++ [ pkgs.python3 ];
      extraInstallPhase = ''
        mkdir -p "$out/$(dirname ${outputPath})" "$out/metadata" "$out/reports/config_0"
        cp "$build_dir/${outputPath}" "$out/${outputPath}"
        cp "$build_dir/reports/config_0/"*.rpt "$out/reports/config_0/"
        cp "$build_dir/${physicalPath}" "$out/${physicalPath}"
        ${lib.optionalString reports ''
          cp "$build_dir/reports/config_0/validation.json" "$out/reports/config_0/"
        ''}
        ${writeImplementationStageManifest { inherit spec; }}
      '';
      description = "Coyote ${boardProfile.platform} BUILD_APP immutable ${phase} stage";
    };

  opt = mkPhysicalStage {
    phase = "opt";
    predecessor = link;
    predecessorPhase = "link";
    predecessorRole = "linked-checkpoint";
    inputPath = "checkpoints/config_0/shell_linked_c0.dcp";
    outputPath = "checkpoints/config_0/shell_opted_c0.dcp";
    outputRole = "optimized-checkpoint";
    strategy.opt = implementationDirectives.opt;
    extraFlags = [ "-DIMPLEMENTATION_OPT_DIRECTIVE:STRING=${implementationDirectives.opt}" ];
  };

  place = mkPhysicalStage {
    phase = "place";
    predecessor = opt;
    predecessorPhase = "opt";
    predecessorRole = "optimized-checkpoint";
    inputPath = "checkpoints/config_0/shell_opted_c0.dcp";
    outputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
    outputRole = "placed-checkpoint";
    strategy = {
      place = implementationDirectives.place;
      physOpt = implementationDirectives.physOpt;
    };
    extraFlags = [
      "-DIMPLEMENTATION_PLACE_DIRECTIVE:STRING=${implementationDirectives.place}"
      "-DIMPLEMENTATION_PHYS_OPT_DIRECTIVE:STRING=${implementationDirectives.physOpt}"
    ];
  };

  route = mkPhysicalStage {
    phase = "route";
    predecessor = place;
    predecessorPhase = "place";
    predecessorRole = "placed-checkpoint";
    inputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
    outputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
    outputRole = "routed-checkpoint";
    strategy = {
      route = implementationDirectives.route;
      postRoutePhysOpt = implementationDirectives.postRoutePhysOpt;
      finalRoute = implementationDirectives.finalRoute;
    };
    extraFlags = [
      "-DIMPLEMENTATION_ROUTE_DIRECTIVE:STRING=${implementationDirectives.route}"
      "-DIMPLEMENTATION_POST_ROUTE_PHYS_OPT_DIRECTIVE:STRING=${implementationDirectives.postRoutePhysOpt}"
      "-DIMPLEMENTATION_FINAL_ROUTE_DIRECTIVE:STRING=${implementationDirectives.finalRoute}"
    ];
  };

  validate = mkPhysicalStage {
    phase = "validate";
    predecessor = route;
    predecessorPhase = "route";
    predecessorRole = "routed-checkpoint";
    inputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
    outputPath = "checkpoints/config_0/shell_routed_c0.dcp";
    outputRole = "validated-checkpoint";
    reports = true;
    strategy.enforceTiming = if checkedImplementationEnforceTiming == null then "project" else checkedImplementationEnforceTiming;
    extraFlags = lib.optionals (checkedImplementationEnforceTiming != null) [
      "-DIMPLEMENTATION_ENFORCE_TIMING:STRING=${if checkedImplementationEnforceTiming then "1" else "0"}"
    ];
  };

  validationGate = mkImplementationStageGate {
    pname = "${pname}-validation-gate";
    stage = validate;
    expectedContext = implementationContext.id;
  };
  routed = validationGate;

  contract = {
    schemaVersion = 1;
    api = "coyote-nix.two-stage/v1";
    kind = "app";
    inherit version xilinxVersion;
    board = boardProfile.board;
    platform = boardProfile.platform;
    coyotePlatform = boardProfile.coyotePlatform;
    fpgaArchitecture = boardProfile.fpgaArchitecture;
    fpgaPart = boardProfile.fpgaPart;
    coyoteSource = toString coyoteRoot;
    hardwareSource = toString hwSource;
    shellPath = toString shellPackage;
    expectedBitstreams = appExpectedBitstreams;
    metadataPath = "metadata/app.json";
    shellMetadataPath = "metadata/shell.json";
    inherit appCmakeFlags shellPackage;
    stageNames = [
      "synth"
      "app-route"
      "bitgen"
    ];
    physical = {
      api = "coyote-nix.implementation-stage/v2";
      context = implementationContext;
      resources.cores = checkedImplementationCores;
      directives = implementationDirectives;
      stages = {
        inputs = implementationInputs;
        inherit link opt place route validate;
        gate = validationGate;
        image = "self";
      };
    };
  };

  imageSpec = mkImplementationSpec {
    name = "image";
    phase = "image";
    artifactRole = null;
    artifactPath = null;
    predecessorPath = validate;
    strategy = { };
    outcome = "accepted";
    artifacts = (map (artifact: {
      role = "image-${builtins.replaceStrings [ "/" "." ] [ "-" "-" ] artifact}";
      path = "bitstreams/${artifact}";
    }) appExpectedBitstreams) ++ [
      { role = "primary-tool-invocation"; path = "metadata/primary-tool.json"; }
    ];
  };

  final = mkStage {
    inherit pname xilinxVersion;
    board = boardProfile;
    cores = checkedImplementationCores;
    cmakeFlags = appImplementationBaseFlags ++ [ "-DSHELL_PATH=${implementationInputs}" ];
    preBuildSetup = ''
      test -e ${validationGate}/metadata/outcome
      ${importImplementationStageArtifacts {
        previousStage = validate;
        roles = [ "validated-checkpoint" ];
        expectedPhase = "validate";
        expectedContext = implementationContext.id;
      }}
      mkdir -p "$build_dir/reports/config_0"
      cp -a ${validate}/reports/config_0/. "$build_dir/reports/config_0/"
    '';
    buildCommands = [
      (finalBitgenCommand appExpectedBitstreams)
    ];
    expectedPaths = map (artifact: "bitstreams/${artifact}") appExpectedBitstreams;
    nativeBuildInputs = stageNativeBuildInputs;
    extraInstallPhase = ''
      ${installAppExport}
      ${writeImplementationStageManifest { spec = imageSpec; }}
    '';
    extraAttrs = {
      passthru.coyoteTwoStage = contract // {
        stages = {
          inherit synth routed link opt place route validate validationGate implementationInputs;
        };
      };
    };
    description = "Coyote ${boardProfile.platform} BUILD_APP partial artifacts";
  };
in
final
