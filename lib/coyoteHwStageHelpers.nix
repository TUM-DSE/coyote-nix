{
  pkgs,
  tools,
  coyoteRoot,
  hwSource,
  xilinxShareRoot,
  xilinxShell ? null,
  version ? "0.1.0",
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
        nativeBuildInputs
        cores
        checkTimingLog
        extraAttrs
        ;
      platform = board.platform;
      coyotePlatform = board.coyotePlatform;
    };

  implementationStageTool = ../nix/tools/coyote-implementation-stage.py;

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
      ${pkgs.python3}/bin/python ${implementationStageTool} validate ${previousStage}${lib.optionalString (expectedPhase != null) " --phase ${lib.escapeShellArg expectedPhase}"}${lib.optionalString (expectedContext != null) " --context ${lib.escapeShellArg expectedContext}"}
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
    }:
    pkgs.runCommand pname { nativeBuildInputs = [ pkgs.jq pkgs.python3 ]; } ''
      ${pkgs.python3}/bin/python ${implementationStageTool} validate \
        ${stage} --phase validate --context ${lib.escapeShellArg expectedContext}
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
