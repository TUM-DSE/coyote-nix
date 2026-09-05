{
  pkgs,
  tools,
  coyoteRoot,
  baseCoyoteRoot ? coyoteRoot,
  coyoteSourceDelta ? null,
  hwSource,
  xilinxShareRoot,
  xilinxShell ? null,
  version ? "0.1.0",
  requiresVitisHls ? true,
}:

let
  lib = pkgs.lib;
  mkCoyoteHwStagePackage = import ./mkCoyoteHwStagePackage.nix;
in
rec {
  mkStage =
    {
      pname,
      board,
      xilinxVersion,
      cmakeFlags ? [ ],
      buildCommands ? [ ],
      expectedPaths ? [ ],
      preConfigureSetup ? "",
      preBuildSetup ? "",
      extraInstallPhase ? "",
      description ? "Coyote hardware build stage for ${board.platform}",
      nativeBuildInputs ? [ ],
      cores ? 8,
      checkTimingLog ? true,
      extraAttrs ? { },
    }:
    mkCoyoteHwStagePackage {
      inherit
        pkgs
        tools
        coyoteRoot
        hwSource
        xilinxShell
        xilinxShareRoot
        pname
        version
        xilinxVersion
        cmakeFlags
        buildCommands
        expectedPaths
        preBuildSetup
        extraInstallPhase
        description
        cores
        checkTimingLog
        requiresVitisHls
        ;
      preConfigureSetup =
        lib.optionalString (coyoteSourceDelta != null) coyoteSourceDelta.verificationCommand
        + preConfigureSetup;
      nativeBuildInputs =
        nativeBuildInputs
        ++ lib.optionals (coyoteSourceDelta != null) [
          pkgs.git
          pkgs.python3
        ];
      extraAttrs = lib.recursiveUpdate extraAttrs {
        passthru.coyoteBuildSource = {
          api = "coyote-nix.coyote-build-source/v1";
          sourceDeltaVerified = coyoteSourceDelta != null;
          baseSource = toString baseCoyoteRoot;
          effectiveSource = toString coyoteRoot;
          baseCoyoteSourceId = builtins.hashString "sha256" (
            builtins.unsafeDiscardStringContext (toString baseCoyoteRoot)
          );
          coyoteSourceId = builtins.hashString "sha256" (
            builtins.unsafeDiscardStringContext (toString coyoteRoot)
          );
          coyoteSourceDeltaId = if coyoteSourceDelta == null then null else coyoteSourceDelta.contractId;
        };
      };
      platform = board.platform;
      coyotePlatform = board.coyotePlatform;
    };

  appElaborationTool = ../nix/tools/coyote-app-elaboration.tcl;
  protectedStaticIntegrityTool = ../nix/tools/coyote-protected-static-integrity.tcl;

  mkProtectedStaticIntegrityGate =
    {
      phase,
      board,
      referenceCheckpoint,
      candidateCheckpoint,
      referenceContract,
      referenceContractId,
      partitionPaths,
      reportDirectory ? "reports/source-delta-${phase}",
      expectedReferenceCheckpointSha256 ? null,
    }:
    let
      validPhase = builtins.elem phase [
        "link"
        "place"
        "route"
      ];
      isSha256 = value: builtins.isString value && builtins.match "[0-9a-f]{64}" value != null;
      isCanonicalRelativePath =
        value:
        builtins.isString value && builtins.match "[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*" value != null;
      isContextBoundPath =
        value:
        builtins.isPath value
        || lib.isDerivation value
        || (builtins.isString value && builtins.attrNames (builtins.getContext value) != [ ]);
      canonicalPartitionPaths =
        if builtins.isList partitionPaths then lib.sort builtins.lessThan partitionPaths else [ ];
      outputDirectory = reportDirectory;
      gatePath = "${outputDirectory}/gate.json";
      evidenceFiles = [
        "reference-partition-pins.tsv"
        "candidate-partition-pins.tsv"
        "reference-static-placement.tsv"
        "candidate-static-placement.tsv"
        "reference-static-routing.tsv"
        "candidate-static-routing.tsv"
      ];
      expectedPaths = [ gatePath ] ++ map (name: "${outputDirectory}/${name}") evidenceFiles;
      artifacts = [
        {
          role = "${phase}-protected-static-integrity";
          path = gatePath;
        }
      ]
      ++ map (name: {
        role = "${phase}-protected-static-${lib.removeSuffix ".tsv" name}";
        path = "${outputDirectory}/${name}";
      }) evidenceFiles;
      checked =
        if coyoteSourceDelta == null then
          throw "coyote-nix: protected-static source-delta integrity requires a verified source delta"
        else if !validPhase then
          throw "coyote-nix: protected-static integrity supports only link, place, and route"
        else if !isSha256 referenceContractId then
          throw "coyote-nix: protected-static integrity referenceContractId must be a lowercase SHA-256 digest"
        else if
          expectedReferenceCheckpointSha256 != null && !isSha256 expectedReferenceCheckpointSha256
        then
          throw "coyote-nix: protected-static integrity reference checkpoint hash must be a lowercase SHA-256 digest"
        else if !isContextBoundPath referenceCheckpoint || !isContextBoundPath referenceContract then
          throw "coyote-nix: protected-static integrity reference inputs must be immutable Nix paths"
        else if !isCanonicalRelativePath candidateCheckpoint then
          throw "coyote-nix: protected-static integrity candidateCheckpoint must be a canonical relative path"
        else if !isCanonicalRelativePath reportDirectory then
          throw "coyote-nix: protected-static integrity reportDirectory must be a canonical relative path"
        else if
          !builtins.isList partitionPaths
          || partitionPaths == [ ]
          || partitionPaths != canonicalPartitionPaths
          || partitionPaths != lib.unique partitionPaths
          || !builtins.all isCanonicalRelativePath partitionPaths
        then
          throw "coyote-nix: protected-static integrity requires canonical, unique, sorted partition paths"
        else
          true;
      verificationCommand = ''
        jq -e \
          --arg phase ${lib.escapeShellArg phase} \
          --arg board ${lib.escapeShellArg board.board} \
          --arg architecture ${lib.escapeShellArg board.fpgaArchitecture} \
          --arg part ${lib.escapeShellArg board.fpgaPart} \
          --arg xilinxVersion ${lib.escapeShellArg board.xilinxVersion} \
          --arg referenceContractId ${lib.escapeShellArg referenceContractId} \
          --arg baseSourceId ${lib.escapeShellArg coyoteSourceDelta.base.sourceId} \
          --arg candidateSourceId ${lib.escapeShellArg coyoteSourceDelta.candidate.sourceId} \
          --arg effectiveSourceId ${lib.escapeShellArg coyoteSourceDelta.effectiveSourceId} \
          --arg deltaContractId ${lib.escapeShellArg coyoteSourceDelta.contractId} \
          --arg expectedReferenceCheckpointSha256 ${
            lib.escapeShellArg (
              if expectedReferenceCheckpointSha256 == null then "" else expectedReferenceCheckpointSha256
            )
          } \
          --argjson partitionPaths ${lib.escapeShellArg (builtins.toJSON partitionPaths)} \
          '
            .schemaVersion == 1
            and .api == "coyote-nix.protected-static-integrity/v1"
            and .kind == "coyote-protected-static-integrity"
            and .failClosed == true
            and .outcome == "accepted"
            and .phase == $phase
            and .board == $board
            and .fpgaArchitecture == $architecture
            and .fpgaPart == $part
            and .vivadoVersion == $xilinxVersion
            and .partitionPaths == $partitionPaths
            and .reference.contractId == $referenceContractId
            and .reference.baseCoyoteSourceId == $baseSourceId
            and ($expectedReferenceCheckpointSha256 == ""
              or .reference.checkpointSha256 == $expectedReferenceCheckpointSha256)
            and .candidate.candidateCoyoteSourceId == $candidateSourceId
            and .candidate.effectiveCoyoteSourceId == $effectiveSourceId
            and .candidate.sourceDeltaContractId == $deltaContractId
            and (.reference.checkpointSha256 | test("^[0-9a-f]{64}$"))
            and (.reference.contractSha256 | test("^[0-9a-f]{64}$"))
            and (.candidate.checkpointSha256 | test("^[0-9a-f]{64}$"))
            and .partitionPins.identical == true
            and .partitionPins.reference == .partitionPins.candidate
            and .partitionPins.reference.objectCount > 0
            and .partitionPins.reference.physicalLocationCount > 0
            and .partitionPins.reference.pblockSiteCount > 0
            and .protectedStatic.placement.identical == true
            and .protectedStatic.placement.reference == .protectedStatic.placement.candidate
            and .protectedStatic.placement.reference.objectCount > 0
            and .protectedStatic.routing.identical == true
            and .protectedStatic.routing.reference == .protectedStatic.routing.candidate
            and .protectedStatic.routing.reference.objectCount > 0
            and (.evidence | length) == 6
            and ([.evidence[].role] | unique | length) == 6
            and ([.evidence[].path] | sort) == [
              "candidate-partition-pins.tsv",
              "candidate-static-placement.tsv",
              "candidate-static-routing.tsv",
              "reference-partition-pins.tsv",
              "reference-static-placement.tsv",
              "reference-static-routing.tsv"
            ]
            and all(.evidence[];
              (.sha256 | test("^[0-9a-f]{64}$"))
              and (.path | test("^[a-z-]+\\.tsv$")))
            and .reasons == []
          ' "$build_dir/${gatePath}" >/dev/null
        while IFS=$'\t' read -r evidence_path expected_sha256; do
          actual_sha256="$(sha256sum "$build_dir/${outputDirectory}/$evidence_path" | cut -d ' ' -f 1)"
          if [ "$actual_sha256" != "$expected_sha256" ]; then
            echo "ERROR: protected-static integrity evidence hash mismatch: $evidence_path" >&2
            exit 1
          fi
        done < <(jq -r '.evidence[] | [.path, .sha256] | @tsv' "$build_dir/${gatePath}")
      '';
    in
    assert checked;
    {
      inherit
        artifacts
        expectedPaths
        gatePath
        outputDirectory
        verificationCommand
        ;
      command = ''
        vivado -mode tcl -source ${protectedStaticIntegrityTool} -notrace -tclargs \
          ${lib.escapeShellArg phase} \
          ${lib.escapeShellArg (toString referenceCheckpoint)} \
          "$build_dir/${candidateCheckpoint}" \
          ${lib.escapeShellArg (toString referenceContract)} \
          "$build_dir/${outputDirectory}" \
          ${lib.escapeShellArg board.board} \
          ${lib.escapeShellArg board.fpgaArchitecture} \
          ${lib.escapeShellArg board.fpgaPart} \
          ${lib.escapeShellArg board.xilinxVersion} \
          ${lib.escapeShellArg referenceContractId} \
          ${lib.escapeShellArg coyoteSourceDelta.base.sourceId} \
          ${lib.escapeShellArg coyoteSourceDelta.candidate.sourceId} \
          ${lib.escapeShellArg coyoteSourceDelta.effectiveSourceId} \
          ${lib.escapeShellArg coyoteSourceDelta.contractId} \
          ${lib.concatMapStringsSep " \\\n          " lib.escapeShellArg partitionPaths}
        ${verificationCommand}
      '';
      install = ''
        mkdir -p "$out/${outputDirectory}"
        cp "$build_dir/${outputDirectory}/"* "$out/${outputDirectory}/"
      '';
    };

  mkAppElaborationStage =
    {
      pname,
      board,
      xilinxVersion,
      cmakeFlags,
      buildApp,
      buildShell,
      preBuildSetup ? "",
      canonicalBuildDependency ? true,
    }:
    let
      expectedBuildApp = if buildApp then "1" else "0";
      expectedBuildShell = if buildShell then "1" else "0";
      metadata = pkgs.writeText "${pname}.json" (
        builtins.toJSON {
          schemaVersion = 1;
          api = "coyote-nix.app-elaboration/v1";
          kind = "coyote-app-rtl-elaboration";
          board = board.board;
          platform = board.platform;
          fpgaArchitecture = board.fpgaArchitecture;
          fpgaPart = board.fpgaPart;
          inherit xilinxVersion;
          flow = {
            inherit buildApp buildShell;
            rtlOnly = true;
            synthesis = false;
            implementation = false;
          };
          sourceManagementMode = "All";
          coyoteSource = toString coyoteRoot;
          coyoteSourceId = builtins.hashString "sha256" (
            builtins.unsafeDiscardStringContext (toString coyoteRoot)
          );
          baseCoyoteSource = toString baseCoyoteRoot;
          baseCoyoteSourceId = builtins.hashString "sha256" (
            builtins.unsafeDiscardStringContext (toString baseCoyoteRoot)
          );
          coyoteSourceDeltaId = if coyoteSourceDelta == null then null else coyoteSourceDelta.contractId;
          hardwareSource = toString hwSource;
          units = "reports/app-elaboration/units.tsv";
          completion = "reports/app-elaboration/complete";
        }
      );
    in
    mkStage {
      inherit
        pname
        board
        xilinxVersion
        cmakeFlags
        preBuildSetup
        ;
      buildCommands = [
        "make project"
        ''
          vivado -mode tcl -source ${appElaborationTool} -notrace -tclargs \
            "$build_dir/base.tcl" "$build_dir/reports/app-elaboration" \
            '${board.board}' '${board.fpgaPart}' '${expectedBuildApp}' '${expectedBuildShell}'
        ''
      ];
      expectedPaths = [
        "reports/app-elaboration/units.tsv"
        "reports/app-elaboration/complete"
      ];
      nativeBuildInputs = [ pkgs.jq ];
      checkTimingLog = false;
      extraInstallPhase = ''
        mkdir -p "$out/reports/app-elaboration"
        cp "$build_dir/reports/app-elaboration/units.tsv" \
          "$out/reports/app-elaboration/units.tsv"
        cp "$build_dir/reports/app-elaboration/complete" \
          "$out/reports/app-elaboration/complete"
        cp ${metadata} "$out/metadata/elaboration.json"
      '';
      extraAttrs = {
        passthru.coyoteAppElaboration = {
          api = "coyote-nix.app-elaboration/v1";
          board = board.board;
          part = board.fpgaPart;
          inherit
            xilinxVersion
            buildApp
            buildShell
            canonicalBuildDependency
            ;
          rtlOnly = true;
          metadata = "metadata/elaboration.json";
          completion = "reports/app-elaboration/complete";
        };
      };
      description = "Coyote ${board.platform} application RTL elaboration gate";
    };

  implementationStageTool = ../nix/tools/coyote-implementation-stage.py;
  incrementalReferenceTool = ../nix/tools/coyote-incremental-reference.py;
  placementDiagnosisTool = ../nix/tools/coyote-placement-diagnosis.py;
  strictSignoffReportTool = ../nix/tools/coyote-signoff-reports.tcl;
  strictSignoffTool = ../nix/tools/coyote-strict-signoff.py;

  strictSignoffReportArtifacts =
    {
      phase,
      reportDirectory,
      reportPrefix,
      reportSuffix ? "",
    }:
    let
      reportPath = kind: "${reportDirectory}/${reportPrefix}_${kind}${reportSuffix}.rpt";
    in
    [
      {
        role = "${phase}-methodology-report";
        path = reportPath "methodology";
      }
      {
        role = "${phase}-timing-exception-report";
        path = reportPath "timing_exceptions";
      }
      {
        role = "${phase}-bus-skew-report";
        path = reportPath "bus_skew";
      }
      {
        role = "${phase}-clock-interaction-report";
        path = reportPath "clock_interaction";
      }
      {
        role = "${phase}-unconstrained-endpoint-report";
        path = reportPath "unconstrained_endpoints";
      }
      {
        role = "${phase}-unconstrained-endpoint-evidence";
        path = "${reportDirectory}/${reportPrefix}_unconstrained_endpoint_evidence${reportSuffix}.json";
      }
      {
        role = "${phase}-drc-report";
        path = reportPath "drc";
      }
      {
        role = "${phase}-timing-summary-report";
        path = reportPath "timing_summary";
      }
      {
        role = "${phase}-strict-signoff-evidence";
        path = "${reportDirectory}/${reportPrefix}_strict_signoff${reportSuffix}.json";
      }
    ]
    ++
      lib.optionals
        (builtins.elem phase [
          "route"
          "validate"
        ])
        [
          {
            role = "${phase}-route-status-report";
            path = reportPath "route_status";
          }
        ];

  strictSignoffReportCommand =
    {
      phase,
      unit,
      checkpointPath,
      reportDirectory,
      reportPrefix,
      reportSuffix ? "",
      contextFile,
    }:
    let
      routeApplicable =
        if
          builtins.elem phase [
            "route"
            "validate"
          ]
        then
          "1"
        else
          "0";
      evidencePath = "${reportDirectory}/${reportPrefix}_strict_signoff${reportSuffix}.json";
    in
    ''
      vivado -mode tcl -source ${strictSignoffReportTool} -notrace -tclargs \
        ${lib.escapeShellArg phase} "$build_dir/${checkpointPath}" \
        "$build_dir/${reportDirectory}" ${lib.escapeShellArg reportPrefix} \
        ${lib.escapeShellArg reportSuffix} ${routeApplicable}
      ${pkgs.python3}/bin/python ${strictSignoffTool} collect \
        --root "$build_dir" \
        --phase ${lib.escapeShellArg phase} \
        --unit ${lib.escapeShellArg unit} \
        --context ${contextFile} \
        --checkpoint "$build_dir/${checkpointPath}" \
        --report-directory ${lib.escapeShellArg reportDirectory} \
        --report-prefix ${lib.escapeShellArg reportPrefix} \
        --report-suffix ${lib.escapeShellArg reportSuffix} \
        --output "$build_dir/${evidencePath}"
    '';

  mkPlacementDiagnosis =
    {
      pname,
      stage,
      candidateId ? null,
    }:
    pkgs.runCommand pname { nativeBuildInputs = [ pkgs.python3 ]; } ''
      ${pkgs.python3}/bin/python ${implementationStageTool} validate \
        ${stage} --phase place
      mkdir -p "$out/metadata"
      ${pkgs.python3}/bin/python ${placementDiagnosisTool} normalize \
        ${stage} "$out/metadata/diagnosis.json" \
        ${lib.optionalString (candidateId != null) "--candidate-id ${lib.escapeShellArg candidateId}"}
      ln -s ${stage} "$out/place-stage"
    '';

  mkPlacementRecommendation =
    {
      pname,
      diagnoses,
      policy,
    }:
    let
      count = builtins.length diagnoses;
      checkedDiagnoses =
        if count >= 2 && count <= 3 then
          diagnoses
        else
          throw "coyote-nix: placement recommendation requires two or three diagnoses";
      policyFile = pkgs.writeText "${pname}-policy.json" (builtins.toJSON policy);
    in
    pkgs.runCommand pname { nativeBuildInputs = [ pkgs.python3 ]; } ''
      mkdir -p "$out/metadata" "$out/candidates"
      ${pkgs.python3}/bin/python ${placementDiagnosisTool} recommend \
        ${policyFile} "$out/metadata/recommendation.json" \
        ${lib.concatMapStringsSep " " (
          diagnosis: lib.escapeShellArg "${diagnosis}/metadata/diagnosis.json"
        ) checkedDiagnoses}
      ${lib.concatImapStringsSep "\n" (index: diagnosis: ''
        ln -s ${diagnosis} "$out/candidates/${toString index}"
      '') checkedDiagnoses}
    '';

  writeImplementationStageManifest =
    {
      spec,
      artifactRoot ? "$out",
      outputDir ? "$out",
    }:
    ''
      ${pkgs.python3}/bin/python ${implementationStageTool} write \
        ${spec} ${artifactRoot} ${outputDir}
    '';

  importImplementationStageArtifacts =
    {
      previousStage,
      destination ? "$build_dir",
      roles ? [ ],
      expectedPhase ? null,
      expectedContext ? null,
    }:
    ''
      ${pkgs.python3}/bin/python ${implementationStageTool} validate ${previousStage}${
        lib.optionalString (expectedPhase != null) " --phase ${lib.escapeShellArg expectedPhase}"
      }${lib.optionalString (expectedContext != null) " --context ${lib.escapeShellArg expectedContext}"}
      ${pkgs.python3}/bin/python ${implementationStageTool} import \
        ${previousStage} ${destination} \
        ${lib.concatMapStringsSep " " lib.escapeShellArg roles}
      if [ -d ${destination}/checkpoints ]; then
        chmod -R u+w ${destination}/checkpoints
        touch ${destination}/.imported-stage-timestamp
        find ${destination}/checkpoints -type f \
          -exec touch -r ${destination}/.imported-stage-timestamp {} +
      fi
    '';

  mkImplementationStageGate =
    {
      pname,
      stage,
      expectedContext,
      signoffClassification ? null,
    }:
    pkgs.runCommand pname
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.python3
        ];
      }
      ''
        ${pkgs.python3}/bin/python ${implementationStageTool} validate \
          ${stage} --phase validate --context ${lib.escapeShellArg expectedContext}
        strict_result="$TMPDIR/strict-signoff.json"
        strict_args=(
          --stage ${stage}
          --context ${lib.escapeShellArg expectedContext}
          ${lib.optionalString (
            signoffClassification != null
          ) "--classification ${lib.escapeShellArg (toString signoffClassification)}"}
          --output "$strict_result"
        )
        set +e
        ${pkgs.python3}/bin/python ${strictSignoffTool} verify "''${strict_args[@]}"
        strict_status=$?
        set -e
        if [ "$strict_status" -ne 0 ]; then
          echo "ERROR: strict physical signoff rejected validation evidence: ${stage}" >&2
          ${pkgs.jq}/bin/jq . "$strict_result" >&2 || true
          exit "$strict_status"
        fi
        outcome="$(${pkgs.jq}/bin/jq -r '.outcome' ${stage}/metadata/stage.json)"
        if [ "$outcome" != accepted ]; then
          echo "ERROR: implementation validation outcome is $outcome; evidence: ${stage}" >&2
          ${pkgs.jq}/bin/jq -r '.artifacts[] | select(.role == "validation-result") | .path' \
            ${stage}/metadata/stage.json >&2 || true
          exit 1
        fi
        mkdir -p "$out/metadata"
        for directory in checkpoints reports logs; do
          if [ -e ${stage}/"$directory" ]; then
            ln -s ${stage}/"$directory" "$out/$directory"
          fi
        done
        cp ${stage}/metadata/stage.json "$out/metadata/validation-stage.json"
        cp "$strict_result" "$out/metadata/strict-signoff.json"
        printf '%s\n' accepted > "$out/metadata/outcome"
      '';

  copyPreviousStageSetup =
    previousStage:
    {
      checkpointDirs ? [ ],
      reportDirs ? [ ],
      logDirs ? [ ],
      extraDirs ? [ ],
    }:
    let
      mkdirs = [
        "$build_dir/checkpoints"
        "$build_dir/reports"
        "$build_dir/logs"
      ]
      ++ map (dir: "$build_dir/checkpoints/${dir}") checkpointDirs
      ++ map (dir: "$build_dir/reports/${dir}") reportDirs
      ++ map (dir: "$build_dir/logs/${dir}") logDirs
      ++ extraDirs;
    in
    ''
      mkdir -p \
        ${lib.concatStringsSep " \\\n        " mkdirs}
      if [ -d ${previousStage}/checkpoints ]; then
        cp -a ${previousStage}/checkpoints/. "$build_dir/checkpoints/"
        touch "$build_dir/.imported-stage-timestamp"
        find "$build_dir/checkpoints" -type f \
          -exec touch -r "$build_dir/.imported-stage-timestamp" {} +
      fi
      if [ -d ${previousStage}/reports ]; then
        cp -a ${previousStage}/reports/. "$build_dir/reports/"
      fi
      if [ -d ${previousStage}/logs ]; then
        cp -a ${previousStage}/logs/. "$build_dir/logs/"
      fi
      chmod -R u+w "$build_dir/checkpoints" "$build_dir/reports" "$build_dir/logs"
    '';

  installCheckpointReports =
    {
      checkpointDirs ? [ ],
      reportDirs ? [ ],
      copyAllCheckpoints ? false,
      copyAllReports ? false,
    }:
    ''
      mkdir -p "$out/checkpoints" "$out/reports"
      ${lib.optionalString copyAllCheckpoints ''
        cp -r "$build_dir/checkpoints/." "$out/checkpoints/"
      ''}
      ${lib.optionalString (!copyAllCheckpoints) (
        lib.concatMapStringsSep "\n" (dir: ''
          cp -r "$build_dir/checkpoints/${dir}" "$out/checkpoints/"
        '') checkpointDirs
      )}
      ${lib.optionalString copyAllReports ''
        if [ -d "$build_dir/reports" ]; then
          cp -r "$build_dir/reports/." "$out/reports/"
        fi
      ''}
      ${lib.optionalString (!copyAllReports) (
        lib.concatMapStringsSep "\n" (dir: ''
          if [ -d "$build_dir/reports/${dir}" ]; then
            cp -r "$build_dir/reports/${dir}" "$out/reports/"
          fi
        '') reportDirs
      )}
    '';

  installFinalReportsAndArtifacts = artifacts: ''
    ${installCheckpointReports {
      copyAllCheckpoints = true;
      copyAllReports = true;
    }}
    mkdir -p "$out/bitstreams"
    ${lib.concatMapStringsSep "\n" (artifact: ''
      install -m0644 "$build_dir/bitstreams/${artifact}" "$out/bitstreams/${artifact}"
    '') artifacts}
  '';

  finalBitgenCommand = artifacts: ''
    rm -f "$build_dir/bitstreams/complete"
    set +e
    vivado -mode tcl -source "$build_dir/bitgen.tcl" -notrace
    vivado_status=$?
    set -e

    completion_marker="$build_dir/bitstreams/complete"
    mkdir -p "$build_dir/metadata"
    ${pkgs.jq}/bin/jq -n \
      --arg tool vivado \
      --argjson exitCode "$vivado_status" \
      --argjson completionMarkerObserved "$([ -f "$completion_marker" ] && echo true || echo false)" \
      '{
        schemaVersion: 1,
        kind: "coyote-primary-tool-invocation",
        tool: $tool,
        exitCode: $exitCode,
        completionMarkerObserved: $completionMarkerObserved,
        anomaly: (if $exitCode != 0 and $completionMarkerObserved then "post-completion-nonzero-exit" else null end)
      }' > "$build_dir/metadata/primary-tool.json"
    if [ ! -f "$completion_marker" ]; then
      echo "ERROR: Vivado bitgen did not produce its completion marker: $completion_marker" >&2
      if [ "$vivado_status" -ne 0 ]; then
        exit "$vivado_status"
      fi
      exit 1
    fi

    if [ "$vivado_status" -ne 0 ]; then
      missing_artifacts=0
      ${lib.concatMapStringsSep "\n" (artifact: ''
        if [ ! -e "$build_dir/bitstreams/${artifact}" ]; then
          echo "ERROR: Vivado bitgen failed and expected artifact is missing: $build_dir/bitstreams/${artifact}" >&2
          missing_artifacts=1
        fi
      '') artifacts}

      if [ "$missing_artifacts" -ne 0 ]; then
        exit "$vivado_status"
      fi

      echo "WARNING: Vivado bitgen exited with status $vivado_status after writing its completion marker and all expected final artifacts; continuing." >&2
      echo "WARNING: This indicates a failure after the Tcl flow completed; inspect $build_dir/vivado.log." >&2
    fi
  '';

  writeArtifactManifest =
    {
      roots,
      output,
    }:
    ''
      manifest_entries="$TMPDIR/coyote-artifacts.jsonl"
      : > "$manifest_entries"
      ${lib.concatMapStringsSep "\n" (root: ''
        if [ -e "${root}" ]; then
          while IFS= read -r -d $'\0' artifact; do
            relative_path="''${artifact#"$out/"}"
            artifact_sha256="$(sha256sum "$artifact" | cut -d ' ' -f 1)"
            jq -cn \
              --arg path "$relative_path" \
              --arg sha256 "$artifact_sha256" \
              '{ path: $path, sha256: $sha256 }' >> "$manifest_entries"
          done < <(find "${root}" -type f -print0 | sort -z)
        fi
      '') roots}
      jq -s '.' "$manifest_entries" > "${output}"
    '';
}
