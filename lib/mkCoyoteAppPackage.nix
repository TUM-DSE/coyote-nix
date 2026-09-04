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
  combineOptPlace = boardName == "u280" && xilinxVersion == "2023.2";
  collectPhysicalQorAssessment = !combineOptPlace;
  appElaborationEnabled = boardName == "u280";

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
    mkAppElaborationStage
    mkImplementationStageGate
    mkPlacementDiagnosis
    mkPlacementRecommendation
    mkStage
    strictSignoffReportArtifacts
    strictSignoffReportCommand
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
  isImplementationPolicyFlag = flag: builtins.match "^-DSHELL_PATH(:[^=]+)?=.*$" flag != null;
  appImplementationBaseFlags =
    builtins.filter (flag: !isImplementationPolicyFlag flag) appCmakeFlags
    ++ [
      "-DIMMUTABLE_IMPLEMENTATION_STAGES:BOOL=ON"
    ];
  implementationEnforceTiming = implementation.enforceTiming or null;
  checkedImplementationEnforceTiming =
    if implementationEnforceTiming == null || builtins.isBool implementationEnforceTiming then
      implementationEnforceTiming
    else
      throw "coyote-nix: implementation.enforceTiming must be a Boolean when specified";
  signoffClassification = implementation.signoffClassification or null;
  checkedSignoffClassification =
    if
      signoffClassification == null
      || builtins.isPath signoffClassification
      || lib.isDerivation signoffClassification
    then
      signoffClassification
    else
      throw "coyote-nix: implementation.signoffClassification must be an immutable path or derivation";
  effectiveFlagValue =
    name: flags:
    let
      matches = builtins.filter (entry: entry != null) (
        map (flag: builtins.match "^-D${name}(:[^=]+)?=(.*)$" flag) flags
      );
    in
    if matches == [ ] then null else builtins.elemAt (lib.last matches) 1;
  flagIsTrue =
    value:
    builtins.elem value [
      "1"
      "ON"
      "TRUE"
      "YES"
    ];
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
  implementationTopology =
    implementation.topology or {
      configurations = 1;
      regions = 1;
    };
  checkedImplementationTopology =
    if
      implementationTopology == {
        configurations = 1;
        regions = 1;
      }
    then
      implementationTopology
    else
      throw "coyote-nix: immutable physical staging currently supports exactly one configuration and one region";
  implementationCores = implementation.resources.cores or 8;
  checkedImplementationCores =
    if builtins.isInt implementationCores && implementationCores > 0 then
      implementationCores
    else
      throw "coyote-nix: implementation.resources.cores must be a positive integer";
  incrementalReference = implementation.incrementalReference or null;
  checkedIncrementalReference =
    if incrementalReference == null then
      null
    else if boardProfile.board != "u280" then
      throw "coyote-nix: incremental implementation references support only U280"
    else if !lib.isDerivation incrementalReference then
      throw "coyote-nix: implementation.incrementalReference must be an immutable Nix derivation"
    else
      incrementalReference;
  placementPortfolio = implementation.placementPortfolio or null;
  candidateDefinitions =
    if placementPortfolio == null then [ ] else placementPortfolio.candidates or [ ];
  candidateIds = map (candidate: candidate.id or "") candidateDefinitions;
  uniqueCandidateIds = lib.unique candidateIds;
  validCandidateId =
    value: builtins.isString value && builtins.match "[a-z][a-z0-9-]{0,31}" value != null;
  validCandidateResources =
    resources:
    builtins.isAttrs resources
    &&
      builtins.attrNames resources == [
        "cores"
        "licenses"
        "ramMiB"
        "scratchMiB"
      ]
    && builtins.isInt resources.cores
    && resources.cores > 0
    && builtins.isInt resources.ramMiB
    && resources.ramMiB > 0
    && builtins.isInt resources.scratchMiB
    && resources.scratchMiB > 0
    && builtins.isList resources.licenses
    && resources.licenses != [ ]
    && builtins.all (license: builtins.isString license && license != "") resources.licenses;
  validCandidate =
    candidate:
    builtins.isAttrs candidate
    &&
      builtins.attrNames candidate == [
        "id"
        "physOptDirective"
        "placeDirective"
        "resources"
      ]
    && validCandidateId candidate.id
    && builtins.isString candidate.placeDirective
    && candidate.placeDirective != ""
    && builtins.isString candidate.physOptDirective
    && candidate.physOptDirective != ""
    && validCandidateResources candidate.resources;
  routeCandidateIds =
    if placementPortfolio == null then [ ] else placementPortfolio.routeCandidates or [ ];
  checkedPlacementPortfolio =
    if placementPortfolio == null then
      null
    else if boardProfile.board != "v80" then
      throw "coyote-nix: placement portfolios currently support only V80"
    else if builtins.length candidateDefinitions < 2 || builtins.length candidateDefinitions > 3 then
      throw "coyote-nix: a placement portfolio requires two or three candidates"
    else if
      builtins.length uniqueCandidateIds != builtins.length candidateIds
      || !builtins.all validCandidate candidateDefinitions
    then
      throw "coyote-nix: placement candidates require unique canonical IDs, directives, and explicit resources"
    else if
      builtins.length routeCandidateIds > 2
      || builtins.length (lib.unique routeCandidateIds) != builtins.length routeCandidateIds
      || !builtins.all (candidateId: builtins.elem candidateId candidateIds) routeCandidateIds
    then
      throw "coyote-nix: routeCandidates must select at most two distinct declared candidates"
    else if !(placementPortfolio ? recommendationPolicy) then
      throw "coyote-nix: placementPortfolio.recommendationPolicy is required"
    else
      placementPortfolio;
  implementationContextWithoutId = {
    board = boardProfile.board;
    architecture = boardProfile.fpgaArchitecture;
    part = boardProfile.fpgaPart;
    flow = "build-app";
    topology = checkedImplementationTopology;
    sourceId = builtins.hashString "sha256" (toString hwSource);
    coyoteSourceId = builtins.hashString "sha256" (toString coyoteRoot);
    constraintsId = builtins.hashString "sha256" (
      builtins.toJSON {
        source = toString hwSource;
        flags = appImplementationBaseFlags;
      }
    );
    toolId =
      implementation.xilinxInstallationId or "vivado-${xilinxVersion}@${toString xilinxShareRoot}";
    toolVersion = xilinxVersion;
  };
  implementationContext = implementationContextWithoutId // {
    id = builtins.hashString "sha256" (builtins.toJSON implementationContextWithoutId);
  };
  implementationContextJson = builtins.toJSON implementationContext;
  implementationContextFile = pkgs.writeText "${pname}-implementation-context.json" implementationContextJson;
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
      stageResources ? {
        cores = checkedImplementationCores;
      },
    }:
    let
      declaredArtifacts =
        if artifacts != null then
          artifacts
        else
          [
            {
              role = artifactRole;
              path = artifactPath;
            }
          ];
      telemetryArtifacts = lib.optionals (phase != "inputs") (
        [
          {
            role = "execution-evidence";
            path = "metadata/execution.json";
          }
          {
            role = "raw-resource-measurement";
            path = "metadata/gnu-time.txt";
          }
          {
            role = "command-stdout";
            path = "logs/command.stdout.log";
          }
          {
            role = "command-stderr";
            path = "logs/command.stderr.log";
          }
          {
            role = "normalized-telemetry";
            path = "metadata/telemetry.json";
          }
        ]
        ++ lib.optionals (telemetryPhysicalPath != null) [
          {
            role = "physical-observations";
            path = telemetryPhysicalPath;
          }
        ]
      );
    in
    pkgs.writeText "${pname}-${name}-stage-spec.json" (
      builtins.toJSON {
        schemaVersion = 2;
        inherit phase outcome strategy;
        unit = "config_0";
        context = implementationContext;
        resources = stageResources;
        artifacts = declaredArtifacts ++ telemetryArtifacts;
        predecessorPath = if predecessorPath == null then null else toString predecessorPath;
        outcomePath = outcomePath;
        telemetry =
          if phase == "inputs" then
            null
          else
            {
              path = "metadata/telemetry.json";
              executionPath = "metadata/execution.json";
              physicalPath = telemetryPhysicalPath;
            };
      }
    );
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
        stages = lib.optionals appElaborationEnabled [ "elaboration" ] ++ [
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

  elaboration =
    if !appElaborationEnabled then
      null
    else
      mkAppElaborationStage {
        pname = "${pname}-elaboration";
        board = boardProfile;
        inherit xilinxVersion;
        cmakeFlags = appCmakeFlags;
        preBuildSetup = validateShellPackage;
        buildApp = true;
        buildShell = false;
      };

  synth = mkStage {
    pname = "${pname}-synth";
    board = boardProfile;
    inherit xilinxVersion;
    cmakeFlags = appCmakeFlags;
    preBuildSetup =
      validateShellPackage
      + lib.optionalString appElaborationEnabled ''
        test -f ${elaboration}/reports/app-elaboration/complete
        test "$(cat ${elaboration}/reports/app-elaboration/complete)" = \
          'coyote-nix.app-elaboration/v1'
        jq -e \
          --arg board '${boardProfile.board}' \
          --arg part '${boardProfile.fpgaPart}' \
          '.api == "coyote-nix.app-elaboration/v1"
           and .board == $board
           and .fpgaPart == $part
           and .flow.buildApp == true
           and .flow.buildShell == false
           and .flow.rtlOnly == true
           and .flow.synthesis == false
           and .flow.implementation == false' \
          ${elaboration}/metadata/elaboration.json >/dev/null
      '';
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

  inputBundleSpec = pkgs.writeText "${pname}-implementation-inputs-spec.json" (
    builtins.toJSON {
      schemaVersion = 2;
      phase = "inputs";
      unit = "config_0";
      context = implementationContext;
      strategy = { };
      resources.cores = checkedImplementationCores;
      outcome = "complete";
      predecessorPath = null;
      artifacts = [
        {
          role = "shell-contract";
          path = "export.cmake";
        }
        {
          role = "locked-shell-checkpoint";
          path = "checkpoints/shell_routed_locked.dcp";
        }
        {
          role = "user-synthesized-checkpoint";
          path = "checkpoints/config_0/user_synthed_c0_0.dcp";
        }
        {
          role = "shell-metadata";
          path = "metadata/shell.json";
        }
        {
          role = "shell-compatibility-id";
          path = "metadata/compatibility-id";
        }
      ];
    }
  );

  implementationInputs =
    pkgs.runCommand "${pname}-implementation-inputs"
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

  linkSignoffArtifacts = strictSignoffReportArtifacts {
    phase = "link";
    reportDirectory = "reports/config_0";
    reportPrefix = "shell_link";
    reportSuffix = "_c0";
  };
  linkSpec = mkImplementationSpec {
    name = "link";
    phase = "link";
    artifacts = [
      {
        role = "linked-checkpoint";
        path = "checkpoints/config_0/shell_linked_c0.dcp";
      }
      {
        role = "application-partition-pin-manifest";
        path = "reports/config_0/app_link_partition_pins_c0.json";
      }
      {
        role = "application-link-integrity";
        path = "reports/config_0/app_link_integrity_c0.json";
      }
    ]
    ++ linkSignoffArtifacts;
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
    buildCommands = [
      "make app_link"
      (strictSignoffReportCommand {
        phase = "link";
        unit = "config_0";
        checkpointPath = "checkpoints/config_0/shell_linked_c0.dcp";
        reportDirectory = "reports/config_0";
        reportPrefix = "shell_link";
        reportSuffix = "_c0";
        contextFile = implementationContextFile;
      })
    ];
    expectedPaths = [
      "checkpoints/app_link_complete"
      "checkpoints/config_0/shell_linked_c0.dcp"
      "reports/config_0/app_link_partition_pins_c0.json"
      "reports/config_0/app_link_integrity_c0.json"
    ]
    ++ map (artifact: artifact.path) linkSignoffArtifacts;
    nativeBuildInputs = stageNativeBuildInputs ++ [ pkgs.python3 ];
    extraInstallPhase = ''
      partition_manifest="$build_dir/reports/config_0/app_link_partition_pins_c0.json"
      integrity_summary="$build_dir/reports/config_0/app_link_integrity_c0.json"
      export_sha256="$(sha256sum ${implementationInputs}/export.cmake | cut -d ' ' -f 1)"
      checkpoint_sha256="$(sha256sum ${implementationInputs}/checkpoints/shell_routed_locked.dcp | cut -d ' ' -f 1)"
      jq -e \
        --arg board '${boardProfile.board}' \
        --arg architecture '${boardProfile.fpgaArchitecture}' \
        --arg part '${boardProfile.fpgaPart}' \
        --arg exportSha256 "$export_sha256" \
        --arg checkpointSha256 "$checkpoint_sha256" \
        '
          .schemaVersion == 1
          and .api == "coyote.app-link-integrity/v1"
          and .kind == "coyote-application-link-integrity"
          and .outcome == "accepted"
          and .board == $board
          and .fpgaArchitecture == $architecture
          and .fpgaPart == $part
          and .configuration == 0
          and .shell.exportCmakeSha256 == $exportSha256
          and .shell.routedLockedCheckpointSha256 == $checkpointSha256
          and .partitionPins.manifest == "app_link_partition_pins_c0.json"
          and .partitionPins.identical == true
          and .partitionPins.beforeSha256 == .partitionPins.afterSha256
          and (.partitionPins.beforeSha256 | test("^[0-9a-f]{64}$"))
          and .partitionPins.logicalPinCount > 0
          and .partitionPins.physicalLocationCount > 0
          and .partitionPins.pblockSiteCount > 0
          and .partitionPins.locationsPerMillionPblockSites > 0
          and .protectedStatic.placement.identical == true
          and .protectedStatic.placement.before.objectCount > 0
          and .protectedStatic.placement.before == .protectedStatic.placement.after
          and (.protectedStatic.placement.before.sha256 | test("^[0-9a-f]{64}$"))
          and .protectedStatic.routing.identical == true
          and .protectedStatic.routing.before.objectCount > 0
          and .protectedStatic.routing.before == .protectedStatic.routing.after
          and (.protectedStatic.routing.before.sha256 | test("^[0-9a-f]{64}$"))
          and .reasons == []
        ' "$integrity_summary" >/dev/null
      jq -e \
        --arg board '${boardProfile.board}' \
        --arg architecture '${boardProfile.fpgaArchitecture}' \
        --arg part '${boardProfile.fpgaPart}' \
        '
          .schemaVersion == 1
          and .api == "coyote.app-link-partition-pins/v1"
          and .kind == "coyote-application-partition-pin-manifest"
          and .board == $board
          and .fpgaArchitecture == $architecture
          and .fpgaPart == $part
          and .configuration == 0
          and .identical == true
          and .densityUnit == "physical-partition-pin-locations-per-million-pblock-sites"
          and .lockedShell.canonicalSha256 == .linkedApplication.canonicalSha256
          and .lockedShell.canonicalRecordCount == .linkedApplication.canonicalRecordCount
          and .lockedShell.logicalPinCount == .linkedApplication.logicalPinCount
          and .lockedShell.physicalLocationCount == .linkedApplication.physicalLocationCount
          and .lockedShell.uniquePhysicalLocationCount == .linkedApplication.uniquePhysicalLocationCount
          and .lockedShell.pblockSiteCount == .linkedApplication.pblockSiteCount
          and .lockedShell.locationsPerMillionPblockSites == .linkedApplication.locationsPerMillionPblockSites
          and ([.lockedShell, .linkedApplication] | all(
            .logicalPinCount > 0
            and .physicalLocationCount > 0
            and .pblockSiteCount > 0
            and .locationsPerMillionPblockSites > 0
            and (.regions | length) > 0
            and ([.regions[] | select(
              .path != ""
              and .pblock != ""
              and .logicalPinCount == (.pins | length)
              and .logicalPinCount > 0
              and .physicalLocationCount > 0
              and .uniquePhysicalLocationCount > 0
              and .maximumLocationOccupancy > 0
              and .pblockSiteCount > 0
              and .locationsPerMillionPblockSites > 0
              and ((.gridRanges | length) > 0 or (.derivedRanges | length) > 0)
              and ([.pins[] | select(
                .name != ""
                and (.direction == "IN" or .direction == "OUT" or .direction == "INOUT")
                and (.locations | length) > 0
              )] | length) == .logicalPinCount
            )] | length) == (.regions | length)
          ))
        ' "$partition_manifest" >/dev/null
      jq -e --slurpfile pins "$partition_manifest" '
        .partitionPins.beforeSha256 == $pins[0].lockedShell.canonicalSha256
        and .partitionPins.afterSha256 == $pins[0].linkedApplication.canonicalSha256
        and .partitionPins.logicalPinCount == $pins[0].linkedApplication.logicalPinCount
        and .partitionPins.physicalLocationCount == $pins[0].linkedApplication.physicalLocationCount
        and .partitionPins.pblockSiteCount == $pins[0].linkedApplication.pblockSiteCount
        and .partitionPins.locationsPerMillionPblockSites == $pins[0].linkedApplication.locationsPerMillionPblockSites
      ' "$integrity_summary" >/dev/null

      mkdir -p "$out/checkpoints/config_0" "$out/reports/config_0" "$out/metadata"
      cp "$build_dir/checkpoints/config_0/shell_linked_c0.dcp" \
        "$out/checkpoints/config_0/shell_linked_c0.dcp"
      cp "$partition_manifest" "$integrity_summary" "$out/reports/config_0/"
      cp "$build_dir/reports/config_0/"*.rpt "$out/reports/config_0/"
      cp "$build_dir/reports/config_0/shell_link_unconstrained_endpoint_evidence_c0.json" \
        "$build_dir/reports/config_0/shell_link_strict_signoff_c0.json" \
        "$out/reports/config_0/"
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
      stageName ? phase,
      stageResources ? {
        cores = checkedImplementationCores;
      },
      incrementalMode ? "none",
      incrementalEvidence ? false,
      extraPreBuildSetup ? "",
    }:
    let
      reportPrefix = if phase == "validate" then "shell" else "shell_${phase}";
      physicalPath = "reports/config_0/${reportPrefix}_physical_c0.json";
      strictReportPhase = builtins.elem phase [
        "place"
        "route"
        "validate"
      ];
      physicalSignoffArtifacts =
        if strictReportPhase then
          strictSignoffReportArtifacts {
            inherit phase reportPrefix;
            reportDirectory = "reports/config_0";
            reportSuffix = "_c0";
          }
        else
          [
            {
              role = "${phase}-timing-summary-report";
              path = "reports/config_0/${reportPrefix}_timing_summary_c0.rpt";
            }
          ];
      phaseArtifacts = [
        {
          role = "${phase}-utilization-report";
          path = "reports/config_0/${reportPrefix}_utilization_c0.rpt";
        }
      ]
      ++ physicalSignoffArtifacts
      ++
        lib.optionals
          (builtins.elem phase [
            "opt"
            "place"
          ])
          [
            {
              role = "${phase}-qor-assessment-report";
              path = "reports/config_0/${reportPrefix}_qor_assessment_c0.rpt";
            }
          ]
      ++ lib.optionals (phase == "place" && boardProfile.board == "v80") [
        {
          role = "place-diagnosis-observations";
          path = "reports/config_0/${reportPrefix}_diagnosis_c0.json";
        }
        {
          role = "place-congestion-report";
          path = "reports/config_0/${reportPrefix}_congestion_c0.rpt";
        }
        {
          role = "place-complexity-report";
          path = "reports/config_0/${reportPrefix}_complexity_c0.rpt";
        }
        {
          role = "place-logic-level-report";
          path = "reports/config_0/${reportPrefix}_logic_levels_c0.rpt";
        }
        {
          role = "place-high-fanout-report";
          path = "reports/config_0/${reportPrefix}_high_fanout_c0.rpt";
        }
      ]
      ++
        lib.optionals
          (
            incrementalMode == "reference"
            && builtins.elem phase [
              "place"
              "route"
            ]
          )
          [
            {
              role = "incremental-reuse-report";
              path = "reports/config_0/${reportPrefix}_incremental_reuse_c0.rpt";
            }
          ]
      ++ lib.optionals incrementalEvidence [
        {
          role = "incremental-reference-evidence";
          path = "metadata/incremental-reference.json";
        }
      ];
      spec = mkImplementationSpec {
        name = stageName;
        inherit phase stageResources;
        artifacts = [
          {
            role = outputRole;
            path = outputPath;
          }
        ]
        ++ phaseArtifacts
        ++ lib.optionals reports [
          {
            role = "bitstream-drc-report";
            path = "reports/config_0/shell_drc_bitstream_checks_c0.rpt";
          }
          {
            role = "validation-result";
            path = "reports/config_0/validation.json";
          }
        ];
        predecessorPath = predecessor;
        inherit strategy;
        outcome = if phase == "validate" then "accepted" else "complete";
        outcomePath = if reports then "reports/config_0/validation.json" else null;
        telemetryPhysicalPath = physicalPath;
      };
    in
    mkStage {
      pname = "${pname}-${stageName}";
      board = boardProfile;
      inherit xilinxVersion;
      cores = stageResources.cores;
      checkTimingLog = false;
      cmakeFlags =
        appImplementationBaseFlags
        ++ [
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
        ]
        ++ lib.optionals (incrementalMode != "none") [
          "-DIMPLEMENTATION_INCREMENTAL_MODE:STRING=${incrementalMode}"
        ]
        ++ extraFlags;
      preBuildSetup = ''
        ${importImplementationStageArtifacts {
          previousStage = predecessor;
          roles = [ predecessorRole ];
          expectedPhase = predecessorPhase;
          expectedContext = implementationContext.id;
        }}
        ${extraPreBuildSetup}
        ${lib.optionalString
          (
            !collectPhysicalQorAssessment
            && builtins.elem phase [
              "opt"
              "place"
            ]
          )
          ''
            chmod u+w "$build_dir/base.tcl" "$build_dir/physical_stage.tcl"
            ${pkgs.python3}/bin/python3 \
              ${../nix/tools/patch-u280-vivado-2023.2-physical-stage.py} \
              "$build_dir/base.tcl" "$build_dir/physical_stage.tcl"
          ''
        }
      '';
      buildCommands = [
        "make physical_stage"
      ]
      ++ lib.optionals strictReportPhase [
        (strictSignoffReportCommand {
          inherit phase reportPrefix;
          unit = "config_0";
          checkpointPath = outputPath;
          reportDirectory = "reports/config_0";
          reportSuffix = "_c0";
          contextFile = implementationContextFile;
        })
      ];
      expectedPaths = [
        outputPath
        "checkpoints/config_0/${phase}_complete"
        physicalPath
      ]
      ++ map (artifact: artifact.path) phaseArtifacts
      ++ lib.optionals reports [
        "reports/config_0/shell_drc_bitstream_checks_c0.rpt"
        "reports/config_0/validation.json"
      ];
      nativeBuildInputs = stageNativeBuildInputs ++ [ pkgs.python3 ];
      extraInstallPhase = ''
        mkdir -p "$out/$(dirname ${outputPath})" "$out/metadata" "$out/reports/config_0"
        cp "$build_dir/${outputPath}" "$out/${outputPath}"
        cp "$build_dir/reports/config_0/"*.rpt "$out/reports/config_0/"
        cp "$build_dir/${physicalPath}" "$out/${physicalPath}"
        ${lib.optionalString strictReportPhase ''
          cp "$build_dir/reports/config_0/${reportPrefix}_unconstrained_endpoint_evidence_c0.json" \
            "$build_dir/reports/config_0/${reportPrefix}_strict_signoff_c0.json" \
            "$out/reports/config_0/"
        ''}
        ${lib.optionalString (phase == "place" && boardProfile.board == "v80") ''
          cp "$build_dir/reports/config_0/${reportPrefix}_diagnosis_c0.json" "$out/reports/config_0/"
        ''}
        ${lib.optionalString reports ''
          cp "$build_dir/reports/config_0/validation.json" "$out/reports/config_0/"
        ''}
        ${lib.optionalString incrementalEvidence ''
          cp "$build_dir/metadata/incremental-reference.json" "$out/metadata/incremental-reference.json"
        ''}
        ${writeImplementationStageManifest { inherit spec; }}
      '';
      description = "Coyote ${boardProfile.platform} BUILD_APP immutable ${phase} stage";
    };

  opt =
    if combineOptPlace then
      null
    else
      mkPhysicalStage {
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
    predecessor = if combineOptPlace then link else opt;
    predecessorPhase = if combineOptPlace then "link" else "opt";
    predecessorRole = if combineOptPlace then "linked-checkpoint" else "optimized-checkpoint";
    inputPath =
      if combineOptPlace then
        "checkpoints/config_0/shell_linked_c0.dcp"
      else
        "checkpoints/config_0/shell_opted_c0.dcp";
    outputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
    outputRole = "placed-checkpoint";
    strategy =
      lib.optionalAttrs combineOptPlace {
        opt = implementationDirectives.opt;
        combinedOptPlace = true;
      }
      // {
        place = implementationDirectives.place;
        physOpt = implementationDirectives.physOpt;
      };
    extraFlags =
      lib.optionals combineOptPlace [
        "-DIMPLEMENTATION_OPT_DIRECTIVE:STRING=${implementationDirectives.opt}"
      ]
      ++ [
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
    strategy.enforceTiming =
      if checkedImplementationEnforceTiming == null then
        "project"
      else
        checkedImplementationEnforceTiming;
    extraFlags = lib.optionals (checkedImplementationEnforceTiming != null) [
      "-DIMPLEMENTATION_ENFORCE_TIMING:STRING=${if checkedImplementationEnforceTiming then "1" else "0"}"
    ];
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

  incrementalOpt =
    if checkedIncrementalReference == null then
      null
    else
      mkPhysicalStage {
        phase = "opt";
        stageName = "incremental-opt";
        predecessor = link;
        predecessorPhase = "link";
        predecessorRole = "linked-checkpoint";
        inputPath = "checkpoints/config_0/shell_linked_c0.dcp";
        outputPath = "checkpoints/config_0/shell_opted_c0.dcp";
        outputRole = "optimized-checkpoint";
        incrementalMode = "reference";
        incrementalEvidence = true;
        strategy = {
          opt = implementationDirectives.opt;
          incremental = {
            mode = "explicit-reference";
            referencePath = toString checkedIncrementalReference;
            signoffAuthority = false;
          };
        };
        extraFlags = [
          "-DIMPLEMENTATION_OPT_DIRECTIVE:STRING=${implementationDirectives.opt}"
          "-DIMPLEMENTATION_INCREMENTAL_REFERENCE_DCP:FILEPATH=$build_dir/checkpoints/config_0/incremental_reference.dcp"
        ];
        extraPreBuildSetup = incrementalReferenceSetup checkedIncrementalReference;
      };

  incrementalPlace =
    if incrementalOpt == null then
      null
    else
      mkPhysicalStage {
        phase = "place";
        stageName = "incremental-place";
        predecessor = incrementalOpt;
        predecessorPhase = "opt";
        predecessorRole = "optimized-checkpoint";
        inputPath = "checkpoints/config_0/shell_opted_c0.dcp";
        outputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
        outputRole = "placed-checkpoint";
        incrementalMode = "reference";
        strategy = {
          place = implementationDirectives.place;
          physOpt = implementationDirectives.physOpt;
          incremental.mode = "explicit-reference";
        };
        extraFlags = [
          "-DIMPLEMENTATION_PLACE_DIRECTIVE:STRING=${implementationDirectives.place}"
          "-DIMPLEMENTATION_PHYS_OPT_DIRECTIVE:STRING=${implementationDirectives.physOpt}"
        ];
      };

  incrementalRoute =
    if incrementalPlace == null then
      null
    else
      mkPhysicalStage {
        phase = "route";
        stageName = "incremental-route";
        predecessor = incrementalPlace;
        predecessorPhase = "place";
        predecessorRole = "placed-checkpoint";
        inputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
        outputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
        outputRole = "routed-checkpoint";
        incrementalMode = "reference";
        strategy = {
          route = implementationDirectives.route;
          postRoutePhysOpt = implementationDirectives.postRoutePhysOpt;
          finalRoute = implementationDirectives.finalRoute;
          incremental.mode = "explicit-reference";
        };
        extraFlags = [
          "-DIMPLEMENTATION_ROUTE_DIRECTIVE:STRING=${implementationDirectives.route}"
          "-DIMPLEMENTATION_POST_ROUTE_PHYS_OPT_DIRECTIVE:STRING=${implementationDirectives.postRoutePhysOpt}"
          "-DIMPLEMENTATION_FINAL_ROUTE_DIRECTIVE:STRING=${implementationDirectives.finalRoute}"
        ];
      };

  incrementalValidate =
    if incrementalRoute == null then
      null
    else
      mkPhysicalStage {
        phase = "validate";
        stageName = "incremental-validate";
        predecessor = incrementalRoute;
        predecessorPhase = "route";
        predecessorRole = "routed-checkpoint";
        inputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
        outputPath = "checkpoints/config_0/shell_routed_c0.dcp";
        outputRole = "validated-checkpoint";
        reports = true;
        incrementalMode = "reference";
        strategy = {
          incremental.mode = "explicit-reference";
          enforceTiming =
            if checkedImplementationEnforceTiming == null then
              "project"
            else
              checkedImplementationEnforceTiming;
        };
        extraFlags = lib.optionals (checkedImplementationEnforceTiming != null) [
          "-DIMPLEMENTATION_ENFORCE_TIMING:STRING=${if checkedImplementationEnforceTiming then "1" else "0"}"
        ];
      };

  incrementalGate =
    if incrementalValidate == null then
      null
    else
      mkImplementationStageGate {
        pname = "${pname}-incremental-validation-gate";
        stage = incrementalValidate;
        expectedContext = implementationContext.id;
        signoffClassification = checkedSignoffClassification;
      };

  validationGate = mkImplementationStageGate {
    pname = "${pname}-validation-gate";
    stage = validate;
    expectedContext = implementationContext.id;
    signoffClassification = checkedSignoffClassification;
  };
  routed = validationGate;

  mkPortfolioCandidate =
    candidate:
    let
      candidatePlace = mkPhysicalStage {
        phase = "place";
        stageName = "place-${candidate.id}";
        predecessor = opt;
        predecessorPhase = "opt";
        predecessorRole = "optimized-checkpoint";
        inputPath = "checkpoints/config_0/shell_opted_c0.dcp";
        outputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
        outputRole = "placed-checkpoint";
        stageResources = candidate.resources;
        strategy = {
          candidateId = candidate.id;
          place = candidate.placeDirective;
          physOpt = candidate.physOptDirective;
        };
        extraFlags = [
          "-DIMPLEMENTATION_PLACE_DIRECTIVE:STRING=${candidate.placeDirective}"
          "-DIMPLEMENTATION_PHYS_OPT_DIRECTIVE:STRING=${candidate.physOptDirective}"
        ];
      };
      candidateDiagnosis = mkPlacementDiagnosis {
        pname = "${pname}-diagnosis-${candidate.id}";
        stage = candidatePlace;
        candidateId = candidate.id;
      };
      selectedForRoute = builtins.elem candidate.id routeCandidateIds;
      candidateRoute =
        if !selectedForRoute then
          null
        else
          mkPhysicalStage {
            phase = "route";
            stageName = "route-${candidate.id}";
            predecessor = candidatePlace;
            predecessorPhase = "place";
            predecessorRole = "placed-checkpoint";
            inputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
            outputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
            outputRole = "routed-checkpoint";
            stageResources = candidate.resources;
            strategy = {
              candidateId = candidate.id;
              selectionMode = "explicit";
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
      candidateValidate =
        if candidateRoute == null then
          null
        else
          mkPhysicalStage {
            phase = "validate";
            stageName = "validate-${candidate.id}";
            predecessor = candidateRoute;
            predecessorPhase = "route";
            predecessorRole = "routed-checkpoint";
            inputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
            outputPath = "checkpoints/config_0/shell_routed_c0.dcp";
            outputRole = "validated-checkpoint";
            reports = true;
            stageResources = candidate.resources;
            strategy = {
              candidateId = candidate.id;
              selectionMode = "explicit";
              enforceTiming =
                if checkedImplementationEnforceTiming == null then
                  "project"
                else
                  checkedImplementationEnforceTiming;
            };
            extraFlags = lib.optionals (checkedImplementationEnforceTiming != null) [
              "-DIMPLEMENTATION_ENFORCE_TIMING:STRING=${if checkedImplementationEnforceTiming then "1" else "0"}"
            ];
          };
      candidateGate =
        if candidateValidate == null then
          null
        else
          mkImplementationStageGate {
            pname = "${pname}-validation-gate-${candidate.id}";
            stage = candidateValidate;
            expectedContext = implementationContext.id;
            signoffClassification = checkedSignoffClassification;
          };
    in
    {
      definition = candidate;
      place = candidatePlace;
      diagnosis = candidateDiagnosis;
      route = candidateRoute;
      validate = candidateValidate;
      gate = candidateGate;
    };
  placementCandidates = builtins.listToAttrs (
    map (candidate: {
      name = candidate.id;
      value = mkPortfolioCandidate candidate;
    }) candidateDefinitions
  );
  placementRecommendation =
    if checkedPlacementPortfolio == null then
      null
    else
      mkPlacementRecommendation {
        pname = "${pname}-placement-recommendation";
        diagnoses = map (candidate: placementCandidates.${candidate.id}.diagnosis) candidateDefinitions;
        policy = checkedPlacementPortfolio.recommendationPolicy;
      };

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
    stageNames = lib.optionals appElaborationEnabled [ "elaboration" ] ++ [
      "synth"
      "app-route"
      "bitgen"
    ];
    elaboration = {
      api = "coyote-nix.app-elaboration/v1";
      enabled = appElaborationEnabled;
      canonicalBuildDependency = appElaborationEnabled;
      stage = elaboration;
    };
    physical = {
      api = "coyote-nix.implementation-stage/v2";
      linkIntegrity = {
        api = "coyote-nix.app-link-integrity/v1";
        partitionPinManifest = "reports/config_0/app_link_partition_pins_c0.json";
        summary = "reports/config_0/app_link_integrity_c0.json";
        failClosed = true;
      };
      strictSignoff = {
        api = "coyote-nix.strict-signoff-result/v1";
        classificationApi = "coyote-nix.strict-signoff-classification/v1";
        classification =
          if checkedSignoffClassification == null then null else toString checkedSignoffClassification;
        required = true;
      };
      context = implementationContext;
      resources.cores = checkedImplementationCores;
      directives = implementationDirectives;
      inherit combineOptPlace;
      stages = {
        inputs = implementationInputs;
        inherit
          link
          opt
          place
          route
          validate
          ;
        gate = validationGate;
        image = "self";
      };
      incremental =
        if checkedIncrementalReference == null then
          null
        else
          {
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
      placementPortfolio =
        if checkedPlacementPortfolio == null then
          null
        else
          {
            api = "coyote-nix.placement-portfolio/v1";
            maximumCandidates = 3;
            maximumRouteCandidates = 2;
            explicitRouteSelection = true;
            routeCandidates = routeCandidateIds;
            recommendation = placementRecommendation;
            candidates = lib.mapAttrs (_: candidate: {
              inherit (candidate)
                definition
                place
                diagnosis
                route
                validate
                gate
                ;
            }) placementCandidates;
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
    artifacts =
      (map (artifact: {
        role = "image-${builtins.replaceStrings [ "/" "." ] [ "-" "-" ] artifact}";
        path = "bitstreams/${artifact}";
      }) appExpectedBitstreams)
      ++ [
        {
          role = "application-partition-pin-manifest";
          path = "reports/config_0/app_link_partition_pins_c0.json";
        }
        {
          role = "application-link-integrity";
          path = "reports/config_0/app_link_integrity_c0.json";
        }
        {
          role = "primary-tool-invocation";
          path = "metadata/primary-tool.json";
        }
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
      cp -a ${link}/reports/config_0/. "$build_dir/reports/config_0/"
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
          inherit
            elaboration
            synth
            routed
            link
            opt
            place
            route
            validate
            validationGate
            implementationInputs
            placementCandidates
            placementRecommendation
            ;
          incremental =
            if checkedIncrementalReference == null then
              null
            else
              {
                opt = incrementalOpt;
                place = incrementalPlace;
                route = incrementalRoute;
                validate = incrementalValidate;
                gate = incrementalGate;
              };
        };
      };
    };
    description = "Coyote ${boardProfile.platform} BUILD_APP partial artifacts";
  };
in
final
