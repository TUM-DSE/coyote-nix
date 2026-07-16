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
    installCheckpointReports
    mkStage
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

    cp ${shellPackage}/metadata/shell.json "$out/metadata/shell.json"
    cp ${shellPackage}/metadata/compatibility-id "$out/metadata/shell-compatibility-id"

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

  routed = mkStage {
    pname = "${pname}-routed";
    board = boardProfile;
    inherit xilinxVersion;
    cmakeFlags = appCmakeFlags;
    preBuildSetup = ''
      ${validateShellPackage}
      ${copyPreviousStageSetup synth { }}
    '';
    buildCommands = [
      "make project"
      "make app"
    ];
    expectedPaths = [
      "checkpoints/config_0/shell_routed_c0.dcp"
    ];
    nativeBuildInputs = stageNativeBuildInputs;
    extraInstallPhase = installCheckpointReports {
      copyAllCheckpoints = true;
      copyAllReports = true;
    };
    description = "Coyote ${boardProfile.platform} BUILD_APP routed stage";
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
    stageNames = [
      "synth"
      "app-route"
      "bitgen"
    ];
  };

  final = mkStage {
    inherit pname xilinxVersion;
    board = boardProfile;
    cmakeFlags = appCmakeFlags;
    preBuildSetup = ''
      ${validateShellPackage}
      ${copyPreviousStageSetup routed { }}
    '';
    buildCommands = [
      (finalBitgenCommand appExpectedBitstreams)
    ];
    expectedPaths = map (artifact: "bitstreams/${artifact}") appExpectedBitstreams;
    nativeBuildInputs = stageNativeBuildInputs;
    extraInstallPhase = installAppExport;
    extraAttrs = {
      passthru.coyoteTwoStage = contract // {
        stages = { inherit synth routed; };
      };
    };
    description = "Coyote ${boardProfile.platform} BUILD_APP partial artifacts";
  };
in
final
