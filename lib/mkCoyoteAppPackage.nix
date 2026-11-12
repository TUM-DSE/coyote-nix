{
  pkgs,
  tools,
  coyoteRoot,
  userProjectCoyoteSource ? null,
  hwSource,
  xilinxShareRoot,
  xilinxShell ? null,
  requiresVitisHls ? true,
  pname,
  version ? "0.1.0",
  shellPackage,
  board ? null,
  cmakeFlags ? [ ],
  provenance ? { },
  implementation ? { },
  enableElaboration ? false,
  # Fail the build when validation (routing, bitstream DRC, timing) fails.
  # Otherwise the partial bitstreams are built anyway and
  # metadata/validation.json records the result.
  strict ? false,
  # Tools for the application's own generators, added to every stage.
  nativeBuildInputs ? [ ],
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
  appElaborationEnabled = boardName == "u280" || enableElaboration;
  synthesizeBlockDesigns = boardName == "v80";
  checkedBaseCoyoteRoot =
    if checkedShellContract.coyoteSource == toString coyoteRoot then
      coyoteRoot
    else
      throw "coyote-nix: application coyoteRoot must equal the shell's exact Coyote source; use a verified U280 userProjectCoyoteSource delta for a user-project-only repair";
  requestedUserProjectDelta =
    if userProjectCoyoteSource == null then
      null
    else
      import ./validateCoyoteSourceDelta.nix {
        inherit pkgs;
        baseSource = checkedBaseCoyoteRoot;
        sourceDelta = userProjectCoyoteSource;
      };
  checkedUserProjectDelta =
    if requestedUserProjectDelta == null then
      null
    else if boardName != "u280" then
      throw "coyote-nix: a split user-project Coyote source is supported only for U280 applications"
    else
      requestedUserProjectDelta;
  effectiveUserProjectCoyoteRoot =
    if checkedUserProjectDelta == null then checkedBaseCoyoteRoot else checkedUserProjectDelta.source;

  stageHelpers = import ./coyoteHwStageHelpers.nix {
    inherit
      pkgs
      tools
      hwSource
      xilinxShareRoot
      xilinxShell
      version
      requiresVitisHls
      ;
    coyoteRoot = effectiveUserProjectCoyoteRoot;
    baseCoyoteRoot = checkedBaseCoyoteRoot;
    coyoteSourceDelta = checkedUserProjectDelta;
    extraNativeBuildInputs = nativeBuildInputs;
    inherit strict;
  };

  inherit (stageHelpers)
    finalBitgenCommand
    importStageFiles
    installCheckpointReports
    installValidationResult
    mkAppElaborationStage
    mkPlacementDiagnosis
    mkPlacementRecommendation
    mkProtectedStaticIntegrityGate
    mkStage
    mkValidationResult
    writeArtifactManifest
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
  # Whether failed timing counts as a validation failure. It does unless
  # implementation.enforceTiming is false.
  validationTimingFlag = if checkedImplementationEnforceTiming == false then "0" else "1";
  # A strict build fails when validation fails; otherwise the bitstreams are
  # built anyway and carry the validation result.
  checkedStrict =
    if !builtins.isBool strict then
      throw "coyote-nix: strict must be a Boolean"
    else
      lib.warnIf (
        implementation ? signoffClassification
      ) "coyote-nix: implementation.signoffClassification is no longer used and is ignored" strict;
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
  # Vivado 2025.1's router segfaults while building its netlist for V80
  # designs with a reconfigurable partition when it uses several threads
  # (route_design, Phase 1, rt::HARTNetlistBldrBase::buildNetlist). One
  # thread routes the same checkpoint cleanly, so routing on the V80 uses one.
  routeCores = phase: cores: if boardProfile.board == "v80" && phase == "route" then 1 else cores;
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

  sourceDeltaProvenance = lib.optionalAttrs (checkedUserProjectDelta != null) {
    effectiveUserProjectCoyoteSource = toString effectiveUserProjectCoyoteRoot;
    coyoteSourceDelta = {
      api = "coyote-nix.coyote-source-delta/v1";
      failClosed = true;
      policy = checkedUserProjectDelta.policy;
      contractId = checkedUserProjectDelta.contractId;
      baseSourceId = checkedUserProjectDelta.base.sourceId;
      baseRevision = checkedUserProjectDelta.base.revision;
      candidateSourceId = checkedUserProjectDelta.candidate.sourceId;
      candidateRevision = checkedUserProjectDelta.candidate.revision;
      effectiveSourceId = checkedUserProjectDelta.effectiveSourceId;
    };
  };
  sourceDeltaContract = lib.optionalAttrs (checkedUserProjectDelta != null) (
    sourceDeltaProvenance
    // {
      coyoteSourceDelta = sourceDeltaProvenance.coyoteSourceDelta // {
        proof = checkedUserProjectDelta.proof;
      };
    }
  );

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
      }
      // sourceDeltaProvenance;
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
        inherit xilinxVersion synthesizeBlockDesigns;
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
           and .flow.rtlOnly == ${if synthesizeBlockDesigns then "false" else "true"}
           and .flow.synthesis == ${if synthesizeBlockDesigns then "true" else "false"}
           and .flow.applicationRtlOnly == true
           and .flow.synthesizeBlockDesigns == ${if synthesizeBlockDesigns then "true" else "false"}
           and .flow.implementation == false
           ${
             lib.optionalString (checkedUserProjectDelta != null) ''
               and .baseCoyoteSourceId == "${checkedUserProjectDelta.base.sourceId}"
               and .coyoteSourceId == "${checkedUserProjectDelta.effectiveSourceId}"
               and .coyoteSourceDeltaId == "${checkedUserProjectDelta.contractId}"
             ''
           }' \
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

  implementationInputs = pkgs.runCommand "${pname}-implementation-inputs" { } ''
    mkdir -p "$out/checkpoints/config_0" "$out/metadata"
    cp ${shellPackage}/export.cmake "$out/export.cmake"
    cp ${shellPackage}/checkpoints/shell_routed_locked.dcp \
      "$out/checkpoints/shell_routed_locked.dcp"
    cp ${synth}/checkpoints/config_0/user_synthed_c0_0.dcp \
      "$out/checkpoints/config_0/user_synthed_c0_0.dcp"
    cp ${shellPackage}/metadata/shell.json "$out/metadata/shell.json"
    cp ${shellPackage}/metadata/compatibility-id "$out/metadata/compatibility-id"
  '';

  sourceDeltaReferenceContractId = builtins.hashString "sha256" (
    builtins.unsafeDiscardStringContext (toString shellPackage)
  );
  mkAppSourceIntegrity =
    phase: candidateCheckpoint:
    if checkedUserProjectDelta == null then
      null
    else
      mkProtectedStaticIntegrityGate {
        inherit phase;
        board = boardProfile // {
          inherit xilinxVersion;
        };
        referenceCheckpoint = "${shellPackage}/checkpoints/shell_routed_locked.dcp";
        inherit candidateCheckpoint;
        referenceContract = "${shellPackage}/metadata/shell.json";
        referenceContractId = sourceDeltaReferenceContractId;
        partitionPaths = [ "inst_shell/inst_dynamic/inst_user_wrapper_0" ];
        reportDirectory = "reports/config_0/source-delta-${phase}";
      };
  linkSourceIntegrity = mkAppSourceIntegrity "link" "checkpoints/config_0/shell_linked_c0.dcp";
  placeSourceIntegrity = mkAppSourceIntegrity "place" "checkpoints/config_0/shell_phys_opted_c0.dcp";
  routeSourceIntegrity = mkAppSourceIntegrity "route" "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
  appSourceIntegrityGates = lib.optionals (checkedUserProjectDelta != null) [
    linkSourceIntegrity
    placeSourceIntegrity
    routeSourceIntegrity
  ];
  effectiveLinkIntegrityExpectedPaths =
    if checkedUserProjectDelta == null then
      [
        "reports/config_0/app_link_partition_pins_c0.json"
        "reports/config_0/app_link_integrity_c0.json"
      ]
    else
      linkSourceIntegrity.expectedPaths;

  # Copies a stage's reports, which not every stage writes.
  installReports = ''
    mkdir -p "$out/reports/config_0"
    if [ -d "$build_dir/reports/config_0" ]; then
      cp -a "$build_dir/reports/config_0/." "$out/reports/config_0/"
    fi
  '';

  link = mkStage {
    pname = "${pname}-link";
    board = boardProfile;
    inherit xilinxVersion;
    cores = checkedImplementationCores;
    cmakeFlags = appImplementationBaseFlags ++ [ "-DSHELL_PATH=${implementationInputs}" ];
    preBuildSetup = importStageFiles {
      previousStage = implementationInputs;
      paths = [ "checkpoints/config_0/user_synthed_c0_0.dcp" ];
    };
    buildCommands = [
      "make app_link"
    ]
    ++ lib.optionals (checkedUserProjectDelta != null) [ linkSourceIntegrity.command ];
    expectedPaths = [
      "checkpoints/app_link_complete"
      "checkpoints/config_0/shell_linked_c0.dcp"
    ]
    ++ effectiveLinkIntegrityExpectedPaths;
    nativeBuildInputs = stageNativeBuildInputs ++ [ pkgs.python3 ];
    # Coyote's app_link checks that linking left the shell untouched. A partial
    # bitstream that fails this does not fit the shell, so it fails the build
    # regardless of strict.
    extraInstallPhase = ''
      ${lib.optionalString (checkedUserProjectDelta == null) ''
        integrity_summary="$build_dir/reports/config_0/app_link_integrity_c0.json"
        export_sha256="$(sha256sum ${implementationInputs}/export.cmake | cut -d ' ' -f 1)"
        checkpoint_sha256="$(sha256sum ${implementationInputs}/checkpoints/shell_routed_locked.dcp | cut -d ' ' -f 1)"
        if ! jq -e \
          --arg exportSha256 "$export_sha256" \
          --arg checkpointSha256 "$checkpoint_sha256" \
          '
            .outcome == "accepted"
            and .shell.exportCmakeSha256 == $exportSha256
            and .shell.routedLockedCheckpointSha256 == $checkpointSha256
            and .partitionPins.identical == true
            and .protectedStatic.placement.identical == true
            and .protectedStatic.routing.identical == true
          ' "$integrity_summary" >/dev/null; then
          echo "ERROR: the linked application changes the shell; see $integrity_summary" >&2
          jq . "$integrity_summary" >&2 || true
          exit 1
        fi
      ''}

      mkdir -p "$out/checkpoints/config_0"
      cp "$build_dir/checkpoints/config_0/shell_linked_c0.dcp" \
        "$out/checkpoints/config_0/shell_linked_c0.dcp"
      ${installReports}
      ${lib.optionalString (checkedUserProjectDelta != null) ''
        expected_locked_sha256="$(jq -r '.compatibility.shellRoutedLockedDcpSha256' \
          ${shellPackage}/metadata/shell.json)"
        jq -e --arg expected "$expected_locked_sha256" \
          '.reference.checkpointSha256 == $expected' \
          "$build_dir/${linkSourceIntegrity.gatePath}" >/dev/null
        ${linkSourceIntegrity.install}
      ''}
    '';
    description = "Coyote ${boardProfile.platform} BUILD_APP link stage";
  };

  # One Vivado implementation phase (opt, place, route or validate) of Coyote's
  # physical_stage target, starting from the predecessor's output checkpoint.
  mkPhysicalStage =
    {
      phase,
      predecessor,
      inputPath,
      outputPath,
      extraFlags ? [ ],
      stageName ? phase,
      cores ? checkedImplementationCores,
      incrementalMode ? "none",
      extraPreBuildSetup ? "",
    }:
    let
      reportPrefix = if phase == "validate" then "shell" else "shell_${phase}";
      physicalPath = "reports/config_0/${reportPrefix}_physical_c0.json";
      sourceIntegrity =
        if
          checkedUserProjectDelta != null
          && builtins.elem phase [
            "place"
            "route"
          ]
        then
          mkAppSourceIntegrity phase outputPath
        else
          null;
    in
    mkStage {
      pname = "${pname}-${stageName}";
      board = boardProfile;
      inherit xilinxVersion;
      cores = routeCores phase cores;
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
          "-DIMPLEMENTATION_DRC_NAME:STRING=config_0_bitstream_checks"
          "-DIMPLEMENTATION_VALIDATION_SUMMARY:FILEPATH=$build_dir/reports/config_0/validation.json"
          "-DIMPLEMENTATION_TELEMETRY_PATH:FILEPATH=$build_dir/${physicalPath}"
        ]
        ++ lib.optionals (incrementalMode != "none") [
          "-DIMPLEMENTATION_INCREMENTAL_MODE:STRING=${incrementalMode}"
        ]
        ++ extraFlags;
      preBuildSetup = ''
        ${importStageFiles {
          previousStage = predecessor;
          paths = [ inputPath ];
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
      ++ lib.optionals (sourceIntegrity != null) [ sourceIntegrity.command ];
      expectedPaths = [
        outputPath
        "checkpoints/config_0/${phase}_complete"
        physicalPath
      ]
      ++ lib.optionals (phase == "validate") [ "reports/config_0/validation.json" ]
      ++ lib.optionals (sourceIntegrity != null) sourceIntegrity.expectedPaths;
      nativeBuildInputs = stageNativeBuildInputs ++ [ pkgs.python3 ];
      extraInstallPhase = ''
        mkdir -p "$out/$(dirname ${outputPath})"
        cp "$build_dir/${outputPath}" "$out/${outputPath}"
        ${installReports}
        ${lib.optionalString (sourceIntegrity != null) sourceIntegrity.install}
      '';
      description = "Coyote ${boardProfile.platform} BUILD_APP ${phase} stage";
    };

  optFlags = [ "-DIMPLEMENTATION_OPT_DIRECTIVE:STRING=${implementationDirectives.opt}" ];
  placeFlags =
    placeDirective: physOptDirective:
    lib.optionals combineOptPlace optFlags
    ++ [
      "-DIMPLEMENTATION_PLACE_DIRECTIVE:STRING=${placeDirective}"
      "-DIMPLEMENTATION_PHYS_OPT_DIRECTIVE:STRING=${physOptDirective}"
    ];
  routeFlags = [
    "-DIMPLEMENTATION_ROUTE_DIRECTIVE:STRING=${implementationDirectives.route}"
    "-DIMPLEMENTATION_POST_ROUTE_PHYS_OPT_DIRECTIVE:STRING=${implementationDirectives.postRoutePhysOpt}"
    "-DIMPLEMENTATION_FINAL_ROUTE_DIRECTIVE:STRING=${implementationDirectives.finalRoute}"
  ];
  validateFlags = [ "-DIMPLEMENTATION_ENFORCE_TIMING:STRING=${validationTimingFlag}" ];

  opt =
    if combineOptPlace then
      null
    else
      mkPhysicalStage {
        phase = "opt";
        predecessor = link;
        inputPath = "checkpoints/config_0/shell_linked_c0.dcp";
        outputPath = "checkpoints/config_0/shell_opted_c0.dcp";
        extraFlags = optFlags;
      };

  place = mkPhysicalStage {
    phase = "place";
    predecessor = if combineOptPlace then link else opt;
    inputPath =
      if combineOptPlace then
        "checkpoints/config_0/shell_linked_c0.dcp"
      else
        "checkpoints/config_0/shell_opted_c0.dcp";
    outputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
    extraFlags = placeFlags implementationDirectives.place implementationDirectives.physOpt;
  };

  route = mkPhysicalStage {
    phase = "route";
    predecessor = place;
    inputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
    outputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
    extraFlags = routeFlags;
  };

  validate = mkPhysicalStage {
    phase = "validate";
    predecessor = route;
    inputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
    outputPath = "checkpoints/config_0/shell_routed_c0.dcp";
    extraFlags = validateFlags;
  };

  # Experimental (U280): implement the application again, reusing placement
  # and routing from the routed checkpoint of an earlier build.
  incrementalReferenceSetup = reference: ''
    install -D -m0644 ${reference}/checkpoints/config_0/shell_routed_c0.dcp \
      "$build_dir/checkpoints/config_0/incremental_reference.dcp"
  '';

  incrementalOpt =
    if checkedIncrementalReference == null then
      null
    else
      mkPhysicalStage {
        phase = "opt";
        stageName = "incremental-opt";
        predecessor = link;
        inputPath = "checkpoints/config_0/shell_linked_c0.dcp";
        outputPath = "checkpoints/config_0/shell_opted_c0.dcp";
        incrementalMode = "reference";
        extraFlags = optFlags ++ [
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
        inputPath = "checkpoints/config_0/shell_opted_c0.dcp";
        outputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
        incrementalMode = "reference";
        extraFlags = placeFlags implementationDirectives.place implementationDirectives.physOpt;
      };

  incrementalRoute =
    if incrementalPlace == null then
      null
    else
      mkPhysicalStage {
        phase = "route";
        stageName = "incremental-route";
        predecessor = incrementalPlace;
        inputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
        outputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
        incrementalMode = "reference";
        extraFlags = routeFlags;
      };

  incrementalValidate =
    if incrementalRoute == null then
      null
    else
      mkPhysicalStage {
        phase = "validate";
        stageName = "incremental-validate";
        predecessor = incrementalRoute;
        inputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
        outputPath = "checkpoints/config_0/shell_routed_c0.dcp";
        incrementalMode = "reference";
        extraFlags = validateFlags;
      };

  mkAppValidationResult =
    name: stage:
    mkValidationResult {
      pname = "${pname}-${name}";
      inherit stage;
      validationPath = "reports/config_0/validation.json";
      strict = checkedStrict;
    };

  incrementalGate =
    if incrementalValidate == null then
      null
    else
      mkAppValidationResult "incremental-validation" incrementalValidate;

  validationGate = mkAppValidationResult "validation" validate;
  routed = validationGate;

  mkPortfolioCandidate =
    candidate:
    let
      candidatePlace = mkPhysicalStage {
        phase = "place";
        stageName = "place-${candidate.id}";
        predecessor = opt;
        inputPath = "checkpoints/config_0/shell_opted_c0.dcp";
        outputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
        inherit (candidate.resources) cores;
        extraFlags = placeFlags candidate.placeDirective candidate.physOptDirective;
      };
      candidateDiagnosis = mkPlacementDiagnosis {
        pname = "${pname}-diagnosis-${candidate.id}";
        stage = candidatePlace;
        reportDirectory = "reports/config_0";
        reportSuffix = "_c0";
        candidateId = candidate.id;
        strategy = {
          candidateId = candidate.id;
          place = candidate.placeDirective;
          physOpt = candidate.physOptDirective;
        };
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
            inputPath = "checkpoints/config_0/shell_phys_opted_c0.dcp";
            outputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
            inherit (candidate.resources) cores;
            extraFlags = routeFlags;
          };
      candidateValidate =
        if candidateRoute == null then
          null
        else
          mkPhysicalStage {
            phase = "validate";
            stageName = "validate-${candidate.id}";
            predecessor = candidateRoute;
            inputPath = "checkpoints/config_0/shell_routed_unvalidated_c0.dcp";
            outputPath = "checkpoints/config_0/shell_routed_c0.dcp";
            inherit (candidate.resources) cores;
            extraFlags = validateFlags;
          };
      candidateGate =
        if candidateValidate == null then
          null
        else
          mkAppValidationResult "validation-${candidate.id}" candidateValidate;
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
    validationPath = "metadata/validation.json";
    strict = checkedStrict;
    physical = {
      strict = checkedStrict;
      linkIntegrity =
        if checkedUserProjectDelta == null then
          {
            api = "coyote-nix.app-link-integrity/v1";
            partitionPinManifest = "reports/config_0/app_link_partition_pins_c0.json";
            summary = "reports/config_0/app_link_integrity_c0.json";
            failClosed = true;
          }
        else
          {
            api = "coyote-nix.protected-static-integrity/v1";
            failClosed = true;
            referenceContractId = sourceDeltaReferenceContractId;
            partitionPaths = [ "inst_shell/inst_dynamic/inst_user_wrapper_0" ];
            gates = {
              link = linkSourceIntegrity.gatePath;
              place = placeSourceIntegrity.gatePath;
              route = routeSourceIntegrity.gatePath;
            };
          };
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
  }
  // sourceDeltaContract;

  final = mkStage {
    inherit pname xilinxVersion;
    board = boardProfile;
    cores = checkedImplementationCores;
    checkTimingLog = false;
    cmakeFlags = appImplementationBaseFlags ++ [ "-DSHELL_PATH=${implementationInputs}" ];
    preBuildSetup = ''
      test -e ${validationGate}/metadata/outcome
      ${importStageFiles {
        previousStage = validate;
        paths = [ "checkpoints/config_0/shell_routed_c0.dcp" ];
      }}
      mkdir -p "$build_dir/reports/config_0"
      cp -a ${link}/reports/config_0/. "$build_dir/reports/config_0/"
      cp -a ${validate}/reports/config_0/. "$build_dir/reports/config_0/"
      chmod -R u+w "$build_dir/reports/config_0"
      ${lib.optionalString (checkedUserProjectDelta != null) ''
        expected_locked_sha256="$(jq -r '.compatibility.shellRoutedLockedDcpSha256' \
          ${shellPackage}/metadata/shell.json)"
        for descriptor in \
          'link|${link}|${linkSourceIntegrity.gatePath}' \
          'place|${place}|${placeSourceIntegrity.gatePath}' \
          'route|${route}|${routeSourceIntegrity.gatePath}'; do
          IFS='|' read -r phase stage gate_path <<< "$descriptor"
          gate="$stage/$gate_path"
          if [ ! -f "$gate" ]; then
            echo "ERROR: $phase stage lacks its protected-static integrity result" >&2
            exit 1
          fi
          jq -e \
            --arg phase "$phase" \
            --arg expectedReference "$expected_locked_sha256" \
            '.outcome == "accepted"
             and .phase == $phase
             and .reference.checkpointSha256 == $expectedReference
             and .partitionPins.identical == true
             and .protectedStatic.placement.identical == true
             and .protectedStatic.routing.identical == true' "$gate" >/dev/null
          cp -a "$stage/reports/config_0/source-delta-$phase" \
            "$build_dir/reports/config_0/"
        done
      ''}
    '';
    buildCommands = [
      (finalBitgenCommand appExpectedBitstreams)
    ];
    expectedPaths = map (artifact: "bitstreams/${artifact}") appExpectedBitstreams;
    nativeBuildInputs = stageNativeBuildInputs;
    extraInstallPhase = ''
      ${installAppExport}
      ${installValidationResult validationGate}
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
