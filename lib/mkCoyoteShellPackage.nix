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
  shellCmakeFlags = cmakeFlags ++ [
    "-DFDEV_NAME:STRING=${boardProfile.platform}"
    "-DBUILD_APP:STRING=0"
    "-DBUILD_STATIC:STRING=0"
    "-DBUILD_SHELL:STRING=1"
    "-DEN_PR:STRING=1"
    "-DEN_SHELL_PBLOCK:STRING=${enShellPblock}"
    "-DSTATIC_PATH=${toString staticPath}"
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

  synth = mkStage {
    pname = "${pname}-synth";
    board = boardProfile;
    inherit xilinxVersion;
    cmakeFlags = shellCmakeFlags;
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

  routed =
    if boardProfile.fpgaArchitecture == "ultrascale_plus" then
      mkStage {
        pname = "${pname}-routed";
        board = boardProfile;
        inherit xilinxVersion;
        cmakeFlags = shellCmakeFlags;
        preBuildSetup = copyPreviousStageSetup synth { };
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
    preBuildSetup = copyPreviousStageSetup preDynamicStage { };
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
    inherit shellCmakeFlags;
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
        }
        // lib.optionalAttrs (routed != null) { inherit routed; };
      };
    };
    description = "Reusable Coyote ${boardProfile.platform} PR shell export";
  };
in
final
