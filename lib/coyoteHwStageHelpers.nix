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
        extraAttrs
        ;
      platform = board.platform;
      coyotePlatform = board.coyotePlatform;
    };

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
        cp -r ${previousStage}/checkpoints/. "$build_dir/checkpoints/"
      fi
      if [ -d ${previousStage}/reports ]; then
        cp -r ${previousStage}/reports/. "$build_dir/reports/"
      fi
      if [ -d ${previousStage}/logs ]; then
        cp -r ${previousStage}/logs/. "$build_dir/logs/"
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
    set +e
    vivado -mode tcl -source "$build_dir/bitgen.tcl" -notrace
    vivado_status=$?
    set -e

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

      echo "WARNING: Vivado bitgen exited with status $vivado_status, but all expected final artifacts exist; continuing." >&2
      echo "WARNING: This usually indicates a Vivado post-bitgen cleanup/crash after artifact generation; inspect $build_dir/vivado.log if needed." >&2
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
