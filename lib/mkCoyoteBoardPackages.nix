{
  pkgs,
  tools,
  coyoteRoot,
  userProjectCoyoteSource ? null,
  hwSource,
  xilinxShareRoot,
  xilinxShell ? null,
  requiresVitisHls ? true,
  pnamePrefix,
  version ? "0.1.0",
  projectName ? pnamePrefix,
  boards,
}:

let
  lib = pkgs.lib;
  boardDefaults = import ./coyoteBoardProfiles.nix;

  enabledRequestedBoardNames = builtins.attrNames (
    lib.filterAttrs (_name: cfg: cfg.enable or true) boards
  );
  hasImportedU280 =
    enabledRequestedBoardNames == [ "u280" ] && (boards.u280.staticCheckpoint or null) != null;
  requestedUserProjectDelta =
    if userProjectCoyoteSource == null then
      null
    else
      import ./validateCoyoteSourceDelta.nix {
        inherit pkgs;
        baseSource = coyoteRoot;
        sourceDelta = userProjectCoyoteSource;
      };
  checkedUserProjectDelta =
    if requestedUserProjectDelta != null && !hasImportedU280 then
      throw "coyote-nix: a split user-project Coyote source is permitted only for a U280 imported-static flow"
    else
      requestedUserProjectDelta;
  effectiveUserProjectCoyoteRoot =
    if checkedUserProjectDelta == null then coyoteRoot else checkedUserProjectDelta.source;

  staticStageHelpers = import ./coyoteHwStageHelpers.nix {
    inherit
      pkgs
      tools
      coyoteRoot
      hwSource
      xilinxShareRoot
      xilinxShell
      version
      requiresVitisHls
      ;
  };
  userProjectStageHelpers = import ./coyoteHwStageHelpers.nix {
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
    baseCoyoteRoot = coyoteRoot;
    coyoteSourceDelta = checkedUserProjectDelta;
  };

  inherit (userProjectStageHelpers)
    copyPreviousStageSetup
    finalBitgenCommand
    installCheckpointReports
    installFinalReportsAndArtifacts
    mkAppElaborationStage
    mkProtectedStaticIntegrityGate
    mkStage
    ;
  staticMkStage = staticStageHelpers.mkStage;

  mkCoyoteSimPackage =
    {
      pname,
      board,
      xilinxVersion,
      cmakeFlags ? [ ],
      preBuildSetup ? "",
      simset ? "sim_1",
      mode ? "behavioral",
      stageBuilder ? mkStage,
    }:
    stageBuilder {
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

  mkStaticImport =
    {
      pname,
      board,
      contract,
    }:
    pkgs.runCommand pname
      {
        inherit version;
        nativeBuildInputs = [ pkgs.python3 ];
        passthru.coyoteStaticCheckpoint = {
          api = "coyote-nix.u280-static-checkpoint/v1";
          failClosed = true;
          board = board.board;
          architecture = board.fpgaArchitecture;
          part = board.fpgaPart;
          toolVersion = board.xilinxVersion;
          sourceStage = toString contract.stage;
          inherit (contract)
            checkpointSha256
            coyoteSourceId
            fixedRouteNets
            manifestId
            ;
          reportHashesFromManifest = true;
          staticLock = {
            level = "routing";
            protectedScope = "outside:inst_shell";
          };
          applicationLink = {
            reconfigurableCell = "inst_shell";
            preservePartitionPins = true;
            rejectProtectedStaticDrift = true;
          };
        };
      }
      ''
        python3 ${../nix/tools/import-u280-static-checkpoint.py} \
          --implementation-stage-tool ${../nix/tools/coyote-implementation-stage.py} \
          ${lib.escapeShellArg (toString contract.stage)} "$out" \
          --manifest-id ${lib.escapeShellArg contract.manifestId} \
          --checkpoint-sha256 ${lib.escapeShellArg contract.checkpointSha256} \
          --coyote-source-id ${lib.escapeShellArg contract.coyoteSourceId} \
          --fixed-route-nets ${toString contract.fixedRouteNets} \
          --board ${lib.escapeShellArg board.board} \
          --architecture ${lib.escapeShellArg board.fpgaArchitecture} \
          --part ${lib.escapeShellArg board.fpgaPart} \
          --tool-version ${lib.escapeShellArg board.xilinxVersion} \
          --reconfigurable-cell inst_shell
      '';

  mkU280Packages =
    board:
    let
      xilinxVersion = board.xilinxVersion;
      legacyStaticCheckpointDirectory = board.staticCheckpointDirectory or null;
      requestedStaticCheckpoint = board.staticCheckpoint or null;
      importedStaticCheckpoint =
        if legacyStaticCheckpointDirectory != null then
          throw "coyote-nix: staticCheckpointDirectory is not a fail-closed interface; use staticCheckpoint with a validated-stage contract"
        else if requestedStaticCheckpoint == null then
          null
        else if !builtins.isAttrs requestedStaticCheckpoint then
          throw "coyote-nix: U280 staticCheckpoint must be an attribute set"
        else if
          builtins.attrNames requestedStaticCheckpoint != [
            "checkpointSha256"
            "coyoteSourceId"
            "fixedRouteNets"
            "manifestId"
            "stage"
          ]
        then
          throw "coyote-nix: U280 staticCheckpoint requires exactly stage, manifestId, checkpointSha256, coyoteSourceId, and fixedRouteNets"
        else if
          !(
            builtins.isPath requestedStaticCheckpoint.stage || lib.isDerivation requestedStaticCheckpoint.stage
          )
        then
          throw "coyote-nix: U280 staticCheckpoint.stage must be an immutable Nix path or derivation"
        else if
          !builtins.isString requestedStaticCheckpoint.manifestId
          || builtins.match "[0-9a-f]{64}" requestedStaticCheckpoint.manifestId == null
        then
          throw "coyote-nix: U280 staticCheckpoint.manifestId must be a lowercase SHA-256 digest"
        else if
          !builtins.isString requestedStaticCheckpoint.checkpointSha256
          || builtins.match "[0-9a-f]{64}" requestedStaticCheckpoint.checkpointSha256 == null
        then
          throw "coyote-nix: U280 staticCheckpoint.checkpointSha256 must be a lowercase SHA-256 digest"
        else if
          !builtins.isString requestedStaticCheckpoint.coyoteSourceId
          || builtins.match "[0-9a-f]{64}" requestedStaticCheckpoint.coyoteSourceId == null
        then
          throw "coyote-nix: U280 staticCheckpoint.coyoteSourceId must be a lowercase SHA-256 digest"
        else if
          requestedStaticCheckpoint.coyoteSourceId != builtins.hashString "sha256" (toString coyoteRoot)
        then
          throw "coyote-nix: U280 staticCheckpoint Coyote source does not match this build"
        else if
          !builtins.isInt requestedStaticCheckpoint.fixedRouteNets
          || requestedStaticCheckpoint.fixedRouteNets < 1
        then
          throw "coyote-nix: U280 staticCheckpoint.fixedRouteNets must be a positive integer"
        else
          requestedStaticCheckpoint;
      intermediateRouteCheckpoints = lib.optionals (!(board.skipIntermediateRouteCheckpoints or false)) [
        "checkpoints/shell_opted.dcp"
        "checkpoints/shell_placed.dcp"
        "checkpoints/shell_phys_opted.dcp"
      ];
      staticSynth =
        if importedStaticCheckpoint != null then
          null
        else
          staticMkStage {
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

      staticRouted =
        if staticSynth == null then
          null
        else
          staticMkStage {
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

      static =
        if importedStaticCheckpoint != null then
          mkStaticImport {
            pname = board.staticPname or "${pnamePrefix}-${board.platform}-static";
            inherit board;
            contract = importedStaticCheckpoint;
          }
        else
          mkStaticExport {
            pname = board.staticPname or "${pnamePrefix}-${board.platform}-static";
            inherit board;
            routedStage = staticRouted;
          };

      mkImportedStaticIntegrity =
        phase: candidateCheckpoint:
        if checkedUserProjectDelta == null then
          null
        else
          mkProtectedStaticIntegrityGate {
            inherit phase board;
            referenceCheckpoint = "${static}/checkpoints/static_routed_locked_u280.dcp";
            inherit candidateCheckpoint;
            referenceContract = "${static}/metadata/static-checkpoint.json";
            referenceContractId = importedStaticCheckpoint.manifestId;
            expectedReferenceCheckpointSha256 = importedStaticCheckpoint.checkpointSha256;
            partitionPaths = [ "inst_shell" ];
            reportDirectory = "reports/source-delta-${phase}";
          };
      linkIntegrity = mkImportedStaticIntegrity "link" "checkpoints/shell_linked.dcp";
      placeIntegrity = mkImportedStaticIntegrity "place" "checkpoints/shell_phys_opted.dcp";
      routeIntegrity = mkImportedStaticIntegrity "route" "checkpoints/shell_routed.dcp";
      importedStaticIntegrityGates = lib.optionals (checkedUserProjectDelta != null) [
        linkIntegrity
        placeIntegrity
        routeIntegrity
      ];

      synthesisCmakeFlags = [
        "-DBUILD_APP:STRING=0"
        "-DBUILD_STATIC:STRING=0"
        "-DBUILD_SHELL:STRING=1"
      ]
      ++ (board.appCmakeFlags or [ ]);

      elaboration = mkAppElaborationStage {
        pname = board.elaborationPname or "${pnamePrefix}-${board.platform}-elaboration";
        inherit board xilinxVersion;
        cmakeFlags = synthesisCmakeFlags;
        buildApp = false;
        buildShell = true;
      };

      synth = mkStage {
        pname = board.synthPname or "${pnamePrefix}-${board.platform}-synth";
        inherit board xilinxVersion;
        cmakeFlags = synthesisCmakeFlags;
        preBuildSetup = ''
          test -f ${elaboration}/reports/app-elaboration/complete
          test "$(cat ${elaboration}/reports/app-elaboration/complete)" = \
            'coyote-nix.app-elaboration/v1'
          jq -e \
            --arg board '${board.board}' \
            --arg part '${board.fpgaPart}' \
            '.api == "coyote-nix.app-elaboration/v1"
             and .board == $board
             and .fpgaPart == $part
             and .flow.buildApp == false
             and .flow.buildShell == true
             and .flow.rtlOnly == true
             and .flow.synthesis == false
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
        ]
        ++ map (integrity: integrity.command) importedStaticIntegrityGates;
        expectedPaths = [
          "checkpoints/shell/shell_synthed.dcp"
          "checkpoints/config_0/user_synthed_c0_0.dcp"
          "checkpoints/shell_linked.dcp"
        ]
        ++ intermediateRouteCheckpoints
        ++ [
          "checkpoints/shell_routed.dcp"
        ]
        ++ lib.concatMap (integrity: integrity.expectedPaths) importedStaticIntegrityGates;
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
        preBuildSetup =
          copyPreviousStageSetup routed { }
          + lib.optionalString (checkedUserProjectDelta != null) ''
            for phase in link place route; do
              gate=${routed}/reports/source-delta-$phase/gate.json
              if [ ! -f "$gate" ]; then
                echo "ERROR: routed stage lacks $phase protected-static integrity evidence" >&2
                exit 1
              fi
              jq -e \
                --arg phase "$phase" \
                --arg deltaContractId '${checkedUserProjectDelta.contractId}' \
                --arg referenceSha256 '${importedStaticCheckpoint.checkpointSha256}' \
                '.schemaVersion == 1
                 and .api == "coyote-nix.protected-static-integrity/v1"
                 and .failClosed == true
                 and .outcome == "accepted"
                 and .phase == $phase
                 and .reference.baseCoyoteSourceId == "${checkedUserProjectDelta.base.sourceId}"
                 and .candidate.candidateCoyoteSourceId == "${checkedUserProjectDelta.candidate.sourceId}"
                 and .candidate.effectiveCoyoteSourceId == "${checkedUserProjectDelta.effectiveSourceId}"
                 and .candidate.sourceDeltaContractId == $deltaContractId
                 and .reference.checkpointSha256 == $referenceSha256
                 and .partitionPins.identical == true
                 and .protectedStatic.placement.identical == true
                 and .protectedStatic.routing.identical == true
                 and .reasons == []' "$gate" >/dev/null
            done
          ''
          + lib.optionalString (board ? finalEnablePr) ''
            base_tcl="$build_dir/base.tcl"
            expected_en_pr="${if board.finalEnablePr then "1" else "0"}"
            if ! grep -Eq '^set cfg\(en_pr\)[[:space:]]+[01]$' "$base_tcl"; then
              echo "ERROR: generated base.tcl has no canonical cfg(en_pr) assignment" >&2
              exit 1
            fi
            sed -E -i "s|^set cfg\(en_pr\)[[:space:]]+[01]$|set cfg(en_pr)                  $expected_en_pr|" "$base_tcl"
            grep -Eq "^set cfg\(en_pr\)[[:space:]]+$expected_en_pr$" "$base_tcl"
          '';
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
      "${board.elaborationPname or "${pnamePrefix}-${board.platform}-elaboration"}" = elaboration;
      "${board.synthPname or "${pnamePrefix}-${board.platform}-synth"}" = synth;
      "${board.routedPname or "${pnamePrefix}-${board.platform}-routed"}" = routed;
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
      generatedSynth = staticMkStage {
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

      routed = staticMkStage {
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

      final = staticMkStage {
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
          stageBuilder = staticMkStage;
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
