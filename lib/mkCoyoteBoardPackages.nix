{
  pkgs,
  tools,
  coyoteRoot,
  hwSource,
  xilinxShareRoot,
  xilinxShell ? null,
  pnamePrefix,
  version ? "0.1.0",
  projectName ? pnamePrefix,
  boards,
}:

let
  lib = pkgs.lib;
  boardDefaults = import ./coyoteBoardProfiles.nix;

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
    installFinalReportsAndArtifacts
    mkStage
    ;

  mkCoyoteSimPackage =
    {
      pname,
      board,
      xilinxVersion,
      cmakeFlags ? [ ],
      preBuildSetup ? "",
      simset ? "sim_1",
      mode ? "behavioral",
    }:
    mkStage {
      inherit
        pname
        board
        xilinxVersion
        cmakeFlags
        preBuildSetup
        ;
      buildCommands = [
        "make sim"
        ''
                    runtime_prep_script="$build_dir/prepare-sim-runtime.tcl"
                    cat > "$runtime_prep_script" <<EOF
          set proj [file normalize "$build_dir/sim/${projectName}.xpr"]
          open_project \$proj
          launch_simulation -simset ${simset} -mode ${mode} -scripts_only
          close_project
          exit 0
          EOF
                    vivado -mode batch -source "$runtime_prep_script"

                    runtime_dir="$build_dir/sim/${projectName}.sim/${simset}/behav/xsim"
                    if ! find "$runtime_dir" -type f -name compile.sh | grep -q .; then
                      echo "ERROR: launch_simulation -scripts_only did not produce compile.sh under $runtime_dir" >&2
                      exit 1
                    fi
                    if ! find "$runtime_dir" -type f -name elaborate.sh | grep -q .; then
                      echo "ERROR: launch_simulation -scripts_only did not produce elaborate.sh under $runtime_dir" >&2
                      exit 1
                    fi
                    if ! find "$runtime_dir" -type f -name simulate.sh | grep -q .; then
                      echo "ERROR: launch_simulation -scripts_only did not produce simulate.sh under $runtime_dir" >&2
                      exit 1
                    fi
        ''
      ];
      expectedPaths = [ "sim/${projectName}.xpr" ];
      extraInstallPhase = ''
        bash ${../nix/tools/prepare-xdb-sim-runtime.sh} "$build_dir/sim" "$out/project/sim" "${xilinxVersion}" "${projectName}.xpr"
      '';
      description = "Coyote simulation project for ${board.platform}";
    };

  mkStaticExport =
    {
      pname,
      board,
      routedStage,
    }:
    pkgs.stdenvNoCC.mkDerivation {
      inherit pname version;
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;
      installPhase = ''
        runHook preInstall

        mkdir -p "$out/checkpoints" "$out/reports" "$out/logs"
        cp -r ${routedStage}/checkpoints/. "$out/checkpoints/"
        if [ -d ${routedStage}/reports ]; then
          cp -r ${routedStage}/reports/. "$out/reports/"
        fi
        if [ -d ${routedStage}/logs ]; then
          cp -r ${routedStage}/logs/. "$out/logs/"
        fi
        install -m0644 ${routedStage}/checkpoints/static_routed_locked.dcp "$out/checkpoints/static_routed_locked_${board.platform}.dcp"

        runHook postInstall
      '';
      meta = {
        description = "Coyote ${board.platform} static checkpoint export";
        platforms = [ "x86_64-linux" ];
      };
    };

  mkU280Packages =
    board:
    let
      xilinxVersion = board.xilinxVersion;
      intermediateRouteCheckpoints = lib.optionals (!(board.skipIntermediateRouteCheckpoints or false)) [
        "checkpoints/shell_opted.dcp"
        "checkpoints/shell_placed.dcp"
        "checkpoints/shell_phys_opted.dcp"
      ];
      staticSynth = mkStage {
        pname = board.staticSynthPname or "${pnamePrefix}-${board.platform}-static-synth";
        inherit board xilinxVersion;
        cmakeFlags = [
          "-DBUILD_APP:STRING=0"
          "-DBUILD_STATIC:STRING=1"
          "-DBUILD_SHELL:STRING=0"
        ]
        ++ (board.staticCmakeFlags or [ ]);
        buildCommands = [
          "make project"
          "make synth"
        ];
        expectedPaths = [
          "checkpoints/static/static_synthed.dcp"
          "checkpoints/shell/shell_synthed.dcp"
          "checkpoints/config_0/user_synthed_c0_0.dcp"
        ];
        extraInstallPhase = installCheckpointReports {
          checkpointDirs = [
            "static"
            "shell"
            "config_0"
          ];
          reportDirs = [
            "static"
            "shell"
            "config_0"
          ];
        };
        description = "Coyote ${board.platform} static synthesis stage";
      };

      staticRouted = mkStage {
        pname = board.staticRoutedPname or "${pnamePrefix}-${board.platform}-static-routed";
        inherit board xilinxVersion;
        cmakeFlags = [
          "-DBUILD_APP:STRING=0"
          "-DBUILD_STATIC:STRING=1"
          "-DBUILD_SHELL:STRING=0"
        ]
        ++ (board.staticCmakeFlags or [ ]);
        preBuildSetup = copyPreviousStageSetup staticSynth {
          checkpointDirs = [
            "static"
            "shell"
            "config_0"
          ];
          reportDirs = [
            "static"
            "shell"
            "config_0"
          ];
        };
        buildCommands = [
          "make project"
          "make shell"
        ];
        expectedPaths = [
          "checkpoints/static/static_synthed.dcp"
          "checkpoints/shell/shell_synthed.dcp"
          "checkpoints/config_0/user_synthed_c0_0.dcp"
          "checkpoints/shell_linked.dcp"
        ]
        ++ intermediateRouteCheckpoints
        ++ [
          "checkpoints/shell_routed.dcp"
          "checkpoints/static_routed_locked.dcp"
        ];
        extraInstallPhase = installCheckpointReports {
          copyAllCheckpoints = true;
          copyAllReports = true;
        };
        description = "Coyote ${board.platform} static routed checkpoint stage";
      };

      static = mkStaticExport {
        pname = board.staticPname or "${pnamePrefix}-${board.platform}-static";
        inherit board;
        routedStage = staticRouted;
      };

      synth = mkStage {
        pname = board.synthPname or "${pnamePrefix}-${board.platform}-synth";
        inherit board xilinxVersion;
        cmakeFlags = [
          "-DBUILD_APP:STRING=0"
          "-DBUILD_STATIC:STRING=0"
          "-DBUILD_SHELL:STRING=1"
        ]
        ++ (board.appCmakeFlags or [ ]);
        buildCommands = [
          "make project"
          "make synth"
        ];
        expectedPaths = [
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
        description = "Coyote ${board.platform} shell synthesis stage";
      };

      routed = mkStage {
        pname = board.routedPname or "${pnamePrefix}-${board.platform}-routed";
        inherit board xilinxVersion;
        cmakeFlags = [
          "-DBUILD_APP:STRING=0"
          "-DBUILD_STATIC:STRING=0"
          "-DBUILD_SHELL:STRING=1"
          "-DSTATIC_PATH=${static}/checkpoints"
        ]
        ++ (board.appCmakeFlags or [ ]);
        preBuildSetup = copyPreviousStageSetup synth {
          checkpointDirs = [
            "shell"
            "config_0"
          ];
          reportDirs = [
            "shell"
            "config_0"
          ];
        };
        buildCommands = [
          "make project"
          "make shell"
        ];
        expectedPaths = [
          "checkpoints/shell/shell_synthed.dcp"
          "checkpoints/config_0/user_synthed_c0_0.dcp"
          "checkpoints/shell_linked.dcp"
        ]
        ++ intermediateRouteCheckpoints
        ++ [
          "checkpoints/shell_routed.dcp"
        ];
        extraInstallPhase = installCheckpointReports {
          copyAllCheckpoints = true;
          copyAllReports = true;
        };
        description = "Coyote ${board.platform} routed checkpoint stage";
      };

      final = mkStage {
        pname = board.finalPname or "${pnamePrefix}-${board.platform}";
        inherit board xilinxVersion;
        cmakeFlags = [
          "-DBUILD_APP:STRING=0"
          "-DBUILD_STATIC:STRING=0"
          "-DBUILD_SHELL:STRING=1"
          "-DSTATIC_PATH=${static}/checkpoints"
        ]
        ++ (board.appCmakeFlags or [ ]);
        preBuildSetup = copyPreviousStageSetup routed { };
        buildCommands = [
          (finalBitgenCommand board.finalArtifacts)
        ];
        expectedPaths = map (artifact: "bitstreams/${artifact}") board.finalArtifacts;
        extraInstallPhase = installFinalReportsAndArtifacts board.finalArtifacts;
        description = "Coyote hardware build for ${board.platform}";
      };

      simPackages = lib.optionalAttrs (board ? simXilinxVersion && board.simXilinxVersion != null) {
        "${board.simPname or "${pnamePrefix}-${board.platform}-sim"}" = mkCoyoteSimPackage {
          pname = board.simPname or "${pnamePrefix}-${board.platform}-sim";
          inherit board;
          xilinxVersion = board.simXilinxVersion;
          cmakeFlags = board.simCmakeFlags or [ ];
        };
      };
    in
    {
      "${board.staticPname or "${pnamePrefix}-${board.platform}-static"}" = static;
      "${board.finalPname or "${pnamePrefix}-${board.platform}"}" = final;
    }
    // simPackages;

  mkV80Packages =
    board:
    let
      xilinxVersion = board.xilinxVersion;
      includeStaticCheckpoint = board.staticBuild or false;
      synthesisCheckpointDirs = [
        "shell"
        "config_0"
      ]
      ++ lib.optionals includeStaticCheckpoint [ "static" ];
      generatedSynth = mkStage {
        pname = board.synthPname or "${pnamePrefix}-${board.platform}-synth";
        inherit board xilinxVersion;
        cmakeFlags = board.cmakeFlags or [ ];
        buildCommands = [
          "make project"
          "make synth"
        ];
        expectedPaths = [
          "checkpoints/shell/shell_synthed.dcp"
          "checkpoints/config_0/user_synthed_c0_0.dcp"
        ]
        ++ lib.optionals includeStaticCheckpoint [
          "checkpoints/static/static_synthed.dcp"
        ];
        extraInstallPhase = installCheckpointReports {
          checkpointDirs = synthesisCheckpointDirs;
          reportDirs = synthesisCheckpointDirs;
        };
        description = "Coyote ${board.platform} synthesis stage";
      };
      synth = board.synthesisPackage or generatedSynth;

      routed = mkStage {
        pname = board.routedPname or "${pnamePrefix}-${board.platform}-routed";
        inherit board xilinxVersion;
        cmakeFlags = (board.cmakeFlags or [ ]) ++ (board.routedCmakeFlags or [ ]);
        preBuildSetup = copyPreviousStageSetup synth {
          checkpointDirs = synthesisCheckpointDirs;
          reportDirs = synthesisCheckpointDirs;
          logDirs = synthesisCheckpointDirs;
        };
        buildCommands = [
          "make project"
          "make shell"
        ];
        expectedPaths = [
          "checkpoints/shell/shell_synthed.dcp"
          "checkpoints/config_0/user_synthed_c0_0.dcp"
        ]
        ++ lib.optionals includeStaticCheckpoint [
          "checkpoints/static/static_synthed.dcp"
        ]
        ++ [
          "checkpoints/shell_linked.dcp"
          "checkpoints/shell_opted.dcp"
          "checkpoints/shell_placed.dcp"
          "checkpoints/shell_phys_opted.dcp"
          "checkpoints/shell_routed.dcp"
        ];
        extraInstallPhase = installCheckpointReports {
          copyAllCheckpoints = true;
          copyAllReports = true;
        };
        description = "Coyote ${board.platform} routed checkpoint stage";
      };

      final = mkStage {
        pname = board.finalPname or "${pnamePrefix}-${board.platform}";
        inherit board xilinxVersion;
        cmakeFlags = board.cmakeFlags or [ ];
        preBuildSetup = copyPreviousStageSetup routed { };
        buildCommands = [
          (finalBitgenCommand board.finalArtifacts)
        ];
        expectedPaths = map (artifact: "bitstreams/${artifact}") board.finalArtifacts;
        extraInstallPhase = installFinalReportsAndArtifacts board.finalArtifacts;
        description = "Coyote hardware build for ${board.platform}";
      };

      simPackages = lib.optionalAttrs (board ? simXilinxVersion && board.simXilinxVersion != null) {
        "${board.simPname or "${pnamePrefix}-${board.platform}-sim"}" = mkCoyoteSimPackage {
          pname = board.simPname or "${pnamePrefix}-${board.platform}-sim";
          inherit board;
          xilinxVersion = board.simXilinxVersion;
          cmakeFlags = board.simCmakeFlags or [ ];
        };
      };
    in
    {
      "${board.synthPname or "${pnamePrefix}-${board.platform}-synth"}" = synth;
      "${board.routedPname or "${pnamePrefix}-${board.platform}-routed"}" = routed;
      "${board.finalPname or "${pnamePrefix}-${board.platform}"}" = final;
    }
    // simPackages;

  normalizeBoard =
    name: cfg:
    (boardDefaults.${name} or (throw "coyote-nix: unsupported Coyote board flow: ${name}")) // cfg;

  enabledBoards = lib.filterAttrs (_name: cfg: cfg.enable or true) boards;

  boardPackages = lib.mapAttrsToList (
    name: cfg:
    let
      board = normalizeBoard name cfg;
    in
    if board.staticShell or false then mkU280Packages board else mkV80Packages board
  ) enabledBoards;
in
lib.foldl' (acc: attrs: acc // attrs) { } boardPackages
