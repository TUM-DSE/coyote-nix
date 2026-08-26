{
  description = "Reusable Nix tooling for Coyote FPGA development";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    coyote = {
      url = "github:taugoust/Coyote/peer-endpoints";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      coyote,
      ...
    }:
    let
      coyoteNixLib = (import ./lib) // {
        defaultCoyote = coyote;
        defaultCoyoteRevision = coyote.rev;
      };
      linuxSystems = builtins.filter (
        system: builtins.match ".*-linux" system != null
      ) flake-utils.lib.defaultSystems;
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        evalTools = coyoteNixLib.mkTools {
          inherit pkgs;
          coyoteRoot = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
        };
        defaultCoyoteSourceChecks = coyoteNixLib.mkCoyoteSourceChecks {
          inherit pkgs;
          coyoteRoot = coyote;
        };
        runtimeToolTestCoyoteRoot = pkgs.runCommand "coyote-runtime-tool-test-source" { } ''
          mkdir -p "$out/sw/include/coyote" "$out/sw/src"
          cat > "$out/sw/include/coyote/cRcnfg.hpp" <<'EOF'
          #pragma once
          #include <string>
          namespace coyote {
          class cRcnfg {
          public:
            explicit cRcnfg(unsigned int device = 0);
            void reconfigureApp(std::string bitstream_path, int vfid);
          };
          }
          EOF
          cat > "$out/sw/src/cRcnfg.cpp" <<'EOF'
          #include <coyote/cRcnfg.hpp>
          namespace coyote {
          cRcnfg::cRcnfg(unsigned int) { }
          void cRcnfg::reconfigureApp(std::string, int) { }
          }
          EOF
        '';
        runtimeTestTools = coyoteNixLib.mkTools {
          inherit pkgs;
          coyoteRoot = runtimeToolTestCoyoteRoot;
          xilinxShareRoot = "/nonexistent/xilinx";
        };
        embeddedToolFixture = pkgs.runCommand "xilinx-embedded-tool-fixture" { } ''
                    root="$out/2025.1/Vitis"
                    mkdir -p "$root/bin" "$root/gnu/armr5/lin/gcc-arm-none-eabi/bin"
                    : > "$root/.settings64-Vitis.sh"
                    for tool in bootgen armr5-none-eabi-gcc armr5-none-eabi-readelf; do
                      case "$tool" in
                        armr5-*) dir="$root/gnu/armr5/lin/gcc-arm-none-eabi/bin" ;;
                        *) dir="$root/bin" ;;
                      esac
                      cat > "$dir/$tool" <<EOF
          #!${pkgs.bash}/bin/bash
          printf '%s %s\\n' "\$(basename "\$0")" "\$*"
          EOF
                      chmod +x "$dir/$tool"
                    done
        '';
        embeddedTestTools = coyoteNixLib.mkTools {
          inherit pkgs;
          coyoteRoot = runtimeToolTestCoyoteRoot;
          xilinxShareRoot = embeddedToolFixture;
        };
        fakeXilinxShell = pkgs.writeShellScript "fake-xilinx-shell" ''
          test "$1" = -c
          command="$2"
          shift 2
          test "$1" = --
          shift
          exec ${pkgs.bash}/bin/bash -c "$command" -- "$@"
        '';
        fakeBootgen = pkgs.writeShellApplication {
          name = "bootgen";
          text = ''
            test "''${COYOTE_NIX_XILINX_VERSION:-}" = 2025.1
            test "$#" -eq 7
            test "$1" = -arch && test "$2" = versal
            test "$3" = -image && test "$4" = deployment.bif
            test "$5" = -w && test "$6" = -o
            test -f "$4" && test -f platform-base.pdi && test -f firmware.elf
            grep -F 'type=bootimage, file=platform-base.pdi' "$4" >/dev/null
            grep -F 'core=r5-0, file=firmware.elf' "$4" >/dev/null
            printf 'fake bootgen output\n' > "$7"
            sha256sum platform-base.pdi firmware.elf "$4" >> "$7"
          '';
        };
        fakeR5ElfCheck = pkgs.writeShellApplication {
          name = "coyote-r5-elf-check";
          text = ''
            test "$1" = --elf && test -f "$2"
            test "$3" = --contract && test -f "$4"
          '';
        };
        fakeR5Tools = evalTools // {
          bootgen = fakeBootgen;
          r5-elf-check = fakeR5ElfCheck;
        };
        fakePlatformContractId = "platform-contract-fixture";
        fakePlatformContract = pkgs.writeText "platform-contract-fixture.json" (
          builtins.toJSON {
            api = "fixture";
            platformContractId = fakePlatformContractId;
          }
        );
        fakePlatform =
          (pkgs.runCommand "r5-platform-fixture" { nativeBuildInputs = [ pkgs.jq ]; } ''
            mkdir -p "$out/bitstreams" "$out/metadata"
            printf 'base PDI fixture\n' > "$out/bitstreams/cyt_top_base.pdi"
            cp ${fakePlatformContract} "$out/metadata/platform-contract.json"
            base_sha="$(sha256sum "$out/bitstreams/cyt_top_base.pdi" | cut -d' ' -f1)"
            jq -n --arg api 'coyote-nix.v80-r5-platform/v1' \
              --arg platformId 'platform-fixture' \
              --arg platformContractId ${pkgs.lib.escapeShellArg fakePlatformContractId} \
              --arg xilinxVersion '2025.1' --arg subsystemId '0x1c000000' \
              --arg basePdiPath 'bitstreams/cyt_top_base.pdi' --arg baseSha256 "$base_sha" \
              '{api:$api,platformId:$platformId,platformContractId:$platformContractId,
                xilinxVersion:$xilinxVersion,subsystemId:$subsystemId,
                basePdi:{path:$basePdiPath,sha256:$baseSha256}}' > "$out/metadata/platform.json"
          '')
          // {
            coyoteR5Platform = {
              api = "coyote-nix.v80-r5-platform/v1";
              platformId = "platform-fixture";
              platformContractId = fakePlatformContractId;
              subsystemId = "0x1c000000";
              xilinxVersion = "2025.1";
              basePdi = "bitstreams/cyt_top_base.pdi";
              metadata = "metadata/platform.json";
              contract = "metadata/platform-contract.json";
            };
          };
        fakeFirmware =
          (pkgs.runCommand "r5-firmware-fixture" { nativeBuildInputs = [ pkgs.jq ]; } ''
            mkdir -p "$out/firmware" "$out/metadata"
            printf 'ELF fixture\n' > "$out/firmware/r5.elf"
            cp ${fakePlatformContract} "$out/metadata/platform-contract.json"
            elf_sha="$(sha256sum "$out/firmware/r5.elf" | cut -d' ' -f1)"
            firmware_id="$(printf '%s\\0%s\\0%s\\n' 'coyote-nix-r5-firmware-v1' \
              'scratch-probe' "$elf_sha" | sha256sum | cut -d' ' -f1)"
            printf '%s\n' "$firmware_id" > "$out/metadata/firmware-id"
            jq -n --arg api 'coyote-nix.r5-firmware/v1' --arg firmwareAbi 'scratch-probe' \
              --arg firmwareId "$firmware_id" \
              --arg platformContractId ${pkgs.lib.escapeShellArg fakePlatformContractId} \
              --arg elfPath 'firmware/r5.elf' --arg elfSha256 "$elf_sha" \
              '{api:$api,firmwareAbi:$firmwareAbi,firmwareId:$firmwareId,
                platformContractId:$platformContractId,elf:{path:$elfPath,sha256:$elfSha256}}' \
              > "$out/metadata/firmware.json"
          '')
          // {
            coyoteR5Firmware = {
              api = "coyote-nix.r5-firmware/v1";
              firmwareAbi = "scratch-probe";
              platformContractId = fakePlatformContractId;
              elf = "firmware/r5.elf";
              metadata = "metadata/firmware.json";
            };
          };
        fakeR5Deployment = coyoteNixLib.mkCoyoteR5BootPackage {
          inherit pkgs;
          tools = fakeR5Tools;
          pname = "r5-deployment-fixture";
          platformPackage = fakePlatform;
          firmwarePackage = fakeFirmware;
        };
        mismatchedFirmware = fakeFirmware // {
          coyoteR5Firmware = fakeFirmware.coyoteR5Firmware // {
            platformContractId = "wrong-platform-contract";
          };
        };
        mismatchedBootEval = builtins.tryEval (
          (coyoteNixLib.mkCoyoteR5BootPackage {
            inherit pkgs;
            tools = fakeR5Tools;
            pname = "r5-deployment-mismatch";
            platformPackage = fakePlatform;
            firmwarePackage = mismatchedFirmware;
          }).coyoteR5Deployment.api
        );
        evalStageHelpers = import ./lib/coyoteHwStageHelpers.nix {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = ./.;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
        };
        artifactManifestSnippet = evalStageHelpers.writeArtifactManifest {
          roots = [
            "$out/checkpoints"
            "$out/bitstreams"
          ];
          output = "$out/artifacts.json";
        };
        bitgenCompletionSnippet = evalStageHelpers.finalBitgenCommand [ "cyt_top.bit" ];
        evalBoardPackages = coyoteNixLib.mkCoyoteBoardPackages {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = ./.;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pnamePrefix = "example";
          projectName = "example-project";
          boards = {
            u280 = {
              xilinxVersion = "site-selected-u280-build-version";
              simXilinxVersion = "site-selected-u280-sim-version";
            };
            v80 = {
              xilinxVersion = "site-selected-v80-build-version";
            };
          };
        };
        evalU280Shell = coyoteNixLib.mkCoyoteShellPackage {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = ./.;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pname = "example-u280-shell";
          board = "u280";
          xilinxVersion = "2023.2";
          synthesisAnalysis = {
            enable = true;
            enforce = true;
          };
          timingOracle.enforce = true;
        };
        evalV80Shell = coyoteNixLib.mkCoyoteShellPackage {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = ./.;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pname = "example-v80-shell";
          board = "v80";
          xilinxVersion = "site-selected-v80-build-version";
          staticPath = "/nonexistent/external-static-marker";
          synthesisAnalysis = {
            enable = true;
            enforce = true;
            rejectSetupWnsBelow = -0.25;
            passSetupWnsAtLeast = 0.75;
            maximumLogicLevels = 12;
            maxPaths = 64;
            maxFanoutNets = 32;
          };
          timingOracle = {
            enforce = true;
            rejectRqaBelow = 2;
            passRqaAtLeast = 5;
            maxPaths = 64;
          };
        };
        evalV80ShellRetuned = coyoteNixLib.mkCoyoteShellPackage {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = ./.;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pname = "example-v80-shell";
          board = "v80";
          xilinxVersion = "site-selected-v80-build-version";
          staticPath = "/nonexistent/external-static-marker";
          synthesisAnalysis = {
            enable = true;
            enforce = true;
            rejectSetupWnsBelow = -0.5;
            passSetupWnsAtLeast = 1.0;
            maximumLogicLevels = 12;
            maxPaths = 64;
            maxFanoutNets = 32;
          };
          timingOracle = {
            enforce = true;
            rejectRqaBelow = 2;
            passRqaAtLeast = 5;
            maxPaths = 64;
          };
        };
        evalV80ShellRouteRetuned = coyoteNixLib.mkCoyoteShellPackage {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = ./.;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pname = "example-v80-shell";
          board = "v80";
          xilinxVersion = "site-selected-v80-build-version";
          staticPath = "/nonexistent/external-static-marker";
          synthesisAnalysis = {
            enable = true;
            enforce = true;
            rejectSetupWnsBelow = -0.25;
            passSetupWnsAtLeast = 0.75;
            maximumLogicLevels = 12;
            maxPaths = 64;
            maxFanoutNets = 32;
          };
          timingOracle = {
            enforce = true;
            rejectRqaBelow = 2;
            passRqaAtLeast = 5;
            maxPaths = 64;
          };
          implementation.directives.route = "NoTimingRelaxation";
        };
        invalidSynthesisAnalysisEval = builtins.tryEval (
          (coyoteNixLib.mkCoyoteShellPackage {
            inherit pkgs;
            tools = evalTools;
            coyoteRoot = ./.;
            hwSource = ./.;
            xilinxShareRoot = "/nonexistent/xilinx";
            pname = "invalid-synthesis-v80-shell";
            board = "v80";
            xilinxVersion = "site-selected-v80-build-version";
            synthesisAnalysis = {
              enable = true;
              rejectSetupWnsBelow = 1.0;
              passSetupWnsAtLeast = 0.5;
            };
          }).coyoteTwoStage.synthesisAnalysis.policy
        );
        invalidTimingOracleEval = builtins.tryEval (
          (coyoteNixLib.mkCoyoteShellPackage {
            inherit pkgs;
            tools = evalTools;
            coyoteRoot = ./.;
            hwSource = ./.;
            xilinxShareRoot = "/nonexistent/xilinx";
            pname = "invalid-v80-shell";
            board = "v80";
            xilinxVersion = "site-selected-v80-build-version";
            timingOracle = {
              rejectRqaBelow = 4;
              passRqaAtLeast = 3;
            };
          }).coyoteTwoStage.timingOracle.policy
        );
        fakeV80StaticBuild = pkgs.runCommand "fake-v80-static-build" { } ''
          mkdir -p "$out/checkpoints/static" "$out/reports"
          printf 'synthesized static\n' > "$out/checkpoints/static/static_synthed.dcp"
          printf 'routed locked static\n' > "$out/checkpoints/static_routed_locked.dcp"
          printf 'retained report\n' > "$out/reports/static.rpt"
        '';
        evalV80StaticCheckpoints = coyoteNixLib.mkCoyoteV80StaticCheckpointPackage {
          inherit pkgs;
          staticPackage = fakeV80StaticBuild;
          pcieGeneration = 5;
          pname = "example-v80-static-checkpoints";
        };
        invalidV80StaticGenerationEval = builtins.tryEval (
          (coyoteNixLib.mkCoyoteV80StaticCheckpointPackage {
            inherit pkgs;
            staticPackage = fakeV80StaticBuild;
            pcieGeneration = 3;
          }).coyoteV80StaticCheckpoints.pcieGeneration
        );
        evalU280App = coyoteNixLib.mkCoyoteAppPackage {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = ./.;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pname = "example-u280-app";
          shellPackage = evalU280Shell;
        };
        evalV80App = coyoteNixLib.mkCoyoteAppPackage {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = ./.;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pname = "example-v80-app";
          shellPackage = evalV80Shell;
        };
        evalV80AppPortfolio = coyoteNixLib.mkCoyoteAppPackage {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = ./.;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pname = "example-v80-portfolio-app";
          shellPackage = evalV80Shell;
          implementation.placementPortfolio = {
            candidates = [
              {
                id = "balanced";
                placeDirective = "Default";
                physOptDirective = "Explore";
                resources = {
                  cores = 8;
                  ramMiB = 65536;
                  scratchMiB = 131072;
                  licenses = [ "vivado-implementation" ];
                };
              }
              {
                id = "spread";
                placeDirective = "SSI_SpreadLogic_high";
                physOptDirective = "AggressiveExplore";
                resources = {
                  cores = 6;
                  ramMiB = 65536;
                  scratchMiB = 131072;
                  licenses = [ "vivado-implementation" ];
                };
              }
            ];
            routeCandidates = [ "balanced" ];
            recommendationPolicy = {
              schemaVersion = 1;
              api = "coyote-nix.placement-recommendation-policy/v1";
              maxRouteCandidates = 2;
              weights = {
                rqa = 1000000;
                setupSlackPerPs = 1;
                logicLevelPenalty = 100;
                congestionPenalty = 1000;
              };
            };
          };
        };
        invalidUnboundedPortfolioEval = builtins.tryEval (
          (coyoteNixLib.mkCoyoteAppPackage {
            inherit pkgs;
            tools = evalTools;
            coyoteRoot = ./.;
            hwSource = ./.;
            xilinxShareRoot = "/nonexistent/xilinx";
            pname = "invalid-v80-portfolio-app";
            shellPackage = evalV80Shell;
            implementation.placementPortfolio = {
              candidates =
                map
                  (id: {
                    inherit id;
                    placeDirective = "Default";
                    physOptDirective = "Explore";
                    resources = {
                      cores = 8;
                      ramMiB = 65536;
                      scratchMiB = 131072;
                      licenses = [ "vivado-implementation" ];
                    };
                  })
                  [
                    "one"
                    "two"
                    "three"
                    "four"
                  ];
              routeCandidates = [ ];
              recommendationPolicy = { };
            };
          }).coyoteTwoStage.physical.placementPortfolio
        );
        invalidRouteSelectionEval = builtins.tryEval (
          (coyoteNixLib.mkCoyoteAppPackage {
            inherit pkgs;
            tools = evalTools;
            coyoteRoot = ./.;
            hwSource = ./.;
            xilinxShareRoot = "/nonexistent/xilinx";
            pname = "invalid-v80-route-selection";
            shellPackage = evalV80Shell;
            implementation.placementPortfolio = {
              candidates =
                map
                  (id: {
                    inherit id;
                    placeDirective = "Default";
                    physOptDirective = "Explore";
                    resources = {
                      cores = 8;
                      ramMiB = 65536;
                      scratchMiB = 131072;
                      licenses = [ "vivado-implementation" ];
                    };
                  })
                  [
                    "one"
                    "two"
                    "three"
                  ];
              routeCandidates = [
                "one"
                "two"
                "three"
              ];
              recommendationPolicy = { };
            };
          }).coyoteTwoStage.physical.placementPortfolio
        );
        evalV80AppRetuned = coyoteNixLib.mkCoyoteAppPackage {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = ./.;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pname = "example-v80-app";
          shellPackage = evalV80Shell;
          implementation.directives.route = "NoTimingRelaxation";
        };
        mismatchedAppBoardEval = builtins.tryEval (
          (coyoteNixLib.mkCoyoteAppPackage {
            inherit pkgs;
            tools = evalTools;
            coyoteRoot = ./.;
            hwSource = ./.;
            xilinxShareRoot = "/nonexistent/xilinx";
            pname = "example-mismatched-app";
            shellPackage = evalU280Shell;
            board = "v80";
          }).coyoteTwoStage.board
        );
        twoStageContractFixture = pkgs.writeText "two-stage-contract.json" (
          builtins.toJSON {
            u280 = {
              shellStages = evalU280Shell.coyoteTwoStage.stageNames;
              shellPblock = evalU280Shell.coyoteTwoStage.enShellPblock;
              shellBitstreams = evalU280Shell.coyoteTwoStage.expectedBitstreams;
              appBitstreams = evalU280App.coyoteTwoStage.expectedBitstreams;
            };
            v80 = {
              shellStages = evalV80Shell.coyoteTwoStage.stageNames;
              shellPblock = evalV80Shell.coyoteTwoStage.enShellPblock;
              shellBitstreams = evalV80Shell.coyoteTwoStage.expectedBitstreams;
              appBitstreams = evalV80App.coyoteTwoStage.expectedBitstreams;
            };
          }
        );
        phaseScript = name: text: pkgs.writeText name (builtins.unsafeDiscardStringContext text);
        twoStagePhaseScripts = [
          (phaseScript "u280-shell-build-phase.sh" evalU280Shell.buildPhase)
          (phaseScript "u280-shell-install-phase.sh" evalU280Shell.installPhase)
          (phaseScript "u280-shell-synthesis-analysis-raw-build-phase.sh" evalU280Shell.coyoteTwoStage.stages.synthesisAnalysisRaw.buildPhase)
          (phaseScript "u280-shell-synthesis-analysis-raw-install-phase.sh" evalU280Shell.coyoteTwoStage.stages.synthesisAnalysisRaw.installPhase)
          (phaseScript "u280-shell-timing-oracle-build-phase.sh" evalU280Shell.coyoteTwoStage.stages.timingOracle.buildPhase)
          (phaseScript "u280-shell-timing-oracle-install-phase.sh" evalU280Shell.coyoteTwoStage.stages.timingOracle.installPhase)
          (phaseScript "u280-shell-physical-link-build-phase.sh" evalU280Shell.coyoteTwoStage.physical.units.shell.link.buildPhase)
          (phaseScript "u280-shell-physical-route-build-phase.sh" evalU280Shell.coyoteTwoStage.physical.units.shell.route.buildPhase)
          (phaseScript "u280-shell-config-route-build-phase.sh" evalU280Shell.coyoteTwoStage.physical.units.config_0.route.buildPhase)
          (phaseScript "u280-shell-config-validate-build-phase.sh" evalU280Shell.coyoteTwoStage.physical.units.config_0.validate.buildPhase)
          (phaseScript "u280-shell-config-finalize-build-phase.sh" evalU280Shell.coyoteTwoStage.physical.units.config_0.finalize.buildPhase)
          (phaseScript "u280-app-link-build-phase.sh" evalU280App.coyoteTwoStage.stages.link.buildPhase)
          (phaseScript "u280-app-route-build-phase.sh" evalU280App.coyoteTwoStage.stages.route.buildPhase)
          (phaseScript "u280-app-build-phase.sh" evalU280App.buildPhase)
          (phaseScript "u280-app-install-phase.sh" evalU280App.installPhase)
          (phaseScript "v80-shell-build-phase.sh" evalV80Shell.buildPhase)
          (phaseScript "v80-shell-install-phase.sh" evalV80Shell.installPhase)
          (phaseScript "v80-shell-synthesis-analysis-raw-build-phase.sh" evalV80Shell.coyoteTwoStage.stages.synthesisAnalysisRaw.buildPhase)
          (phaseScript "v80-shell-synthesis-analysis-raw-install-phase.sh" evalV80Shell.coyoteTwoStage.stages.synthesisAnalysisRaw.installPhase)
          (phaseScript "v80-shell-timing-oracle-build-phase.sh" evalV80Shell.coyoteTwoStage.stages.timingOracle.buildPhase)
          (phaseScript "v80-shell-timing-oracle-install-phase.sh" evalV80Shell.coyoteTwoStage.stages.timingOracle.installPhase)
          (phaseScript "v80-shell-link-build-phase.sh" evalV80Shell.coyoteTwoStage.physical.units.config_0.link.buildPhase)
          (phaseScript "v80-shell-route-build-phase.sh" evalV80Shell.coyoteTwoStage.physical.units.config_0.route.buildPhase)
          (phaseScript "v80-shell-validate-build-phase.sh" evalV80Shell.coyoteTwoStage.physical.units.config_0.validate.buildPhase)
          (phaseScript "v80-shell-finalize-build-phase.sh" evalV80Shell.coyoteTwoStage.physical.units.config_0.finalize.buildPhase)
          (phaseScript "v80-app-link-build-phase.sh" evalV80App.coyoteTwoStage.stages.link.buildPhase)
          (phaseScript "v80-app-route-build-phase.sh" evalV80App.coyoteTwoStage.stages.route.buildPhase)
          (phaseScript "v80-app-build-phase.sh" evalV80App.buildPhase)
          (phaseScript "v80-app-install-phase.sh" evalV80App.installPhase)
        ];
      in
      {
        checks.coyote-resident-control-render = defaultCoyoteSourceChecks.renderContract;
        checks.coyote-route-validation-contract = defaultCoyoteSourceChecks.routeValidationContract;
        checks.coyote-resident-control-splitter = defaultCoyoteSourceChecks.splitterSimulation;
        checks.coyote-resident-control-host-api = defaultCoyoteSourceChecks.hostApiCompile;
        checks.coyote-u280-generated-physical-tcl = defaultCoyoteSourceChecks.physicalTclGeneration;

        checks.reconfigure-app =
          assert evalTools ? reconfigure-app;
          pkgs.runCommand "reconfigure-app-check" { } ''
            printf 'partial image\n' > "$TMPDIR/application.bin"
            ${runtimeTestTools.reconfigure-app}/bin/reconfigure-app \
              --dry-run --device 2 --vfpga 3 "$TMPDIR/application.bin" \
              | grep -F "COYOTE_RECONFIGURE_APP_READY device=2 vfpga=3 image=$TMPDIR/application.bin" >/dev/null
            if ${runtimeTestTools.reconfigure-app}/bin/reconfigure-app --dry-run "$TMPDIR/application.bit" >/dev/null 2>&1; then
              echo "ERROR: reconfigure-app accepted a full-image extension" >&2
              exit 1
            fi
            touch $out
          '';

        checks.deploy-hw-image-kind = pkgs.runCommand "deploy-hw-image-kind-check" { } ''
          printf 'partial image\n' > "$TMPDIR/application.bin"
          set +e
          output="$(FPGA_BDF=0000:00:00.0 ${evalTools.deploy-hw}/bin/deploy-hw "$TMPDIR/application.bin" 2>&1)"
          status=$?
          set -e
          test "$status" -ne 0
          printf '%s\n' "$output" | grep -F 'deploy-hw requires a full .bit or .pdi image' >/dev/null
          if printf '%s\n' "$output" | grep -F '[1/7]' >/dev/null; then
            echo "ERROR: deploy-hw began side effects before rejecting a partial image" >&2
            exit 1
          fi
          touch $out
        '';

        checks.shellcheck = pkgs.runCommand "shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          cd ${./.}
          shellcheck -s bash nix/tools/*.sh tests/*.sh
          touch $out
        '';

        checks.xilinx-embedded-wrappers = pkgs.runCommand "xilinx-embedded-wrappers" { } ''
          export COYOTE_NIX_XILINX_VERSION=2025.1
          export COYOTE_NIX_XILINX_SHELL=${fakeXilinxShell}
          test "$(${embeddedTestTools.embedded}/bin/armr5-none-eabi-gcc --version)" = \
            'armr5-none-eabi-gcc --version'
          test "$(${embeddedTestTools.embedded}/bin/armr5-none-eabi-readelf -h probe.elf)" = \
            'armr5-none-eabi-readelf -h probe.elf'
          test "$(${embeddedTestTools.embedded}/bin/bootgen -arch versal)" = \
            'bootgen -arch versal'
          if COYOTE_NIX_XILINX_VERSION=2024.2 \
            ${embeddedTestTools.embedded}/bin/bootgen -help >/dev/null 2>&1; then
            echo "ERROR: wrapper accepted an absent Vitis version" >&2
            exit 1
          fi
          touch $out
        '';

        checks.r5-bif-policy = pkgs.runCommand "r5-bif-policy" { nativeBuildInputs = [ pkgs.python3 ]; } ''
          python3 ${./nix/tools/versal-r5-bif.py} --output good.bif
          python3 ${./nix/tools/versal-r5-bif.py} --check good.bif
          sed 's/delay_handoff//' good.bif > missing-delay.bif
          ! python3 ${./nix/tools/versal-r5-bif.py} --check missing-delay.bif >/dev/null 2>&1
          sed 's/core=r5-0/core=a72-0/' good.bif > wrong-core.bif
          ! python3 ${./nix/tools/versal-r5-bif.py} --check wrong-core.bif >/dev/null 2>&1
          ! python3 ${./nix/tools/versal-r5-bif.py} --output unsafe.bif \
            --firmware-elf ../firmware.elf >/dev/null 2>&1
          ! python3 ${./nix/tools/versal-r5-bif.py} --output unsafe.bif \
            --firmware-elf 'firmware image.elf' >/dev/null 2>&1
          ! python3 ${./nix/tools/versal-r5-bif.py} --output unsafe.bif \
            --firmware-elf $'firmware.elf}\nimage { { core=a72-0' >/dev/null 2>&1
          ! python3 ${./nix/tools/versal-r5-bif.py} --output wrong-subsystem.bif \
            --subsystem-id 0x1c000001 >/dev/null 2>&1
          touch $out
        '';

        checks.r5-boot-package =
          assert !mismatchedBootEval.success;
          pkgs.runCommand "r5-boot-package-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
            test -s ${fakeR5Deployment}/bitstreams/cyt_top.pdi
            grep -F 'type=bootimage, file=platform-base.pdi' \
              ${fakeR5Deployment}/composition/deployment.bif >/dev/null
            grep -F 'id = 0x1c000000, name=rpu_subsystem, delay_handoff' \
              ${fakeR5Deployment}/composition/deployment.bif >/dev/null
            grep -F 'core=r5-0, file=firmware.elf' \
              ${fakeR5Deployment}/composition/deployment.bif >/dev/null
            test "$(jq -r .policy.core ${fakeR5Deployment}/metadata/deployment.json)" = r5-0
            touch $out
          '';

        checks.coprocessor-metadata =
          pkgs.runCommand "coprocessor-metadata"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.jq
                pkgs.gnused
              ];
            }
            ''
              cd ${./.}
              bash tests/coprocessor-metadata.sh
              touch $out
            '';

        checks.synthesis-assessment-result =
          pkgs.runCommand "synthesis-assessment-result-check"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.gawk
                pkgs.jq
              ];
            }
            ''
              cd ${./.}
              bash tests/synthesis-assessment-result.sh \
                nix/tools/assess-synthesis-analysis-result.sh \
                nix/tools/check-synthesis-assessment-result.sh
              touch $out
            '';

        checks.timing-oracle-result =
          pkgs.runCommand "timing-oracle-result-check"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.jq
              ];
            }
            ''
              cd ${./.}
              bash tests/timing-oracle-result.sh nix/tools/check-timing-oracle-result.sh
              touch $out
            '';

        checks.resident-service-metadata =
          pkgs.runCommand "resident-service-metadata"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.jq
                pkgs.gnused
              ];
            }
            ''
              cd ${./.}
              bash tests/resident-service-metadata.sh
              touch $out
            '';

        checks.xilinx-wrapper-gmake-compat =
          pkgs.runCommand "xilinx-wrapper-gmake-compat" { nativeBuildInputs = [ pkgs.bash ]; }
            ''
              cd ${./.}
              bash tests/xilinx-wrapper-gmake-compat.sh
              touch $out
            '';

        checks.board-packages-eval =
          assert
            builtins.attrNames evalBoardPackages == [
              "example-u280"
              "example-u280-sim"
              "example-u280-static"
              "example-v80"
            ];
          pkgs.runCommand "board-packages-eval" { } ''
            touch $out
          '';

        checks.v80-static-checkpoint-package =
          assert !invalidV80StaticGenerationEval.success;
          pkgs.runCommand "v80-static-checkpoint-package-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
            test -f ${evalV80StaticCheckpoints}/checkpoints/static_synthed_v80_gen5.dcp
            test -f ${evalV80StaticCheckpoints}/checkpoints/static_routed_locked_v80_gen5.dcp
            cmp ${fakeV80StaticBuild}/checkpoints/static/static_synthed.dcp \
              ${evalV80StaticCheckpoints}/checkpoints/static_synthed_v80_gen5.dcp
            cmp ${fakeV80StaticBuild}/checkpoints/static_routed_locked.dcp \
              ${evalV80StaticCheckpoints}/checkpoints/static_routed_locked_v80_gen5.dcp
            test -f ${evalV80StaticCheckpoints}/reports/static.rpt
            jq -e '
              .schemaVersion == 1
              and .board == "v80"
              and .pcieGeneration == 5
              and .synthesizedCheckpoint == "checkpoints/static_synthed_v80_gen5.dcp"
              and .routedCheckpoint == "checkpoints/static_routed_locked_v80_gen5.dcp"
            ' ${evalV80StaticCheckpoints}/metadata/v80-static-checkpoints.json >/dev/null
            touch "$out"
          '';

        checks.two-stage-packages-eval =
          assert coyoteNixLib ? mkCoyoteShellPackage;
          assert coyoteNixLib ? mkCoyoteV80StaticCheckpointPackage;
          assert coyoteNixLib ? mkCoyoteSourceChecks;
          assert coyoteNixLib ? mkCoyoteAppPackage;
          assert !invalidSynthesisAnalysisEval.success;
          assert !invalidTimingOracleEval.success;
          assert evalU280Shell.coyoteTwoStage.kind == "shell";
          assert
            evalU280Shell.coyoteTwoStage.stageNames == [
              "synth"
              "routed"
              "dynamic"
              "bitgen"
            ];
          assert evalU280Shell.coyoteTwoStage.stages ? routed;
          assert evalU280Shell.coyoteTwoStage.stages ? synthesisAnalysisRaw;
          assert evalU280Shell.coyoteTwoStage.stages ? synthesisAnalysis;
          assert evalU280Shell.coyoteTwoStage.stages ? synthesisGate;
          assert !evalU280Shell.coyoteTwoStage.synthesisAnalysis.canonicalBuildDependency;
          assert evalU280Shell.coyoteTwoStage.synthesisAnalysis.policy.enable;
          assert evalU280Shell.coyoteTwoStage.synthesisAnalysis.policy.enforce;
          assert evalU280Shell.coyoteTwoStage.synthesisAnalysis.policy.rejectSetupWnsBelow == 0.0;
          assert evalU280Shell.coyoteTwoStage.synthesisAnalysis.policy.passSetupWnsAtLeast == 0.5;
          assert evalU280Shell.coyoteTwoStage.stages ? timingOracle;
          assert evalU280Shell.coyoteTwoStage.stages ? timingGate;
          assert !evalU280Shell.coyoteTwoStage.timingOracle.canonicalBuildDependency;
          assert evalU280Shell.coyoteTwoStage.timingOracle.policy.enforce;
          assert evalU280Shell.coyoteTwoStage.timingOracle.policy.rejectRqaBelow == 3;
          assert evalU280Shell.coyoteTwoStage.enShellPblock;
          assert evalU280Shell.coyoteTwoStage.physical.api == "coyote-nix.implementation-stage/v2";
          assert evalU280Shell.coyoteTwoStage.physical.combineOptPlace;
          assert evalU280Shell.coyoteTwoStage.physical.units ? shell;
          assert evalU280Shell.coyoteTwoStage.physical.units.shell ? link;
          assert evalU280Shell.coyoteTwoStage.physical.units.shell.opt == null;
          assert evalU280Shell.coyoteTwoStage.physical.units.shell ? place;
          assert evalU280Shell.coyoteTwoStage.physical.units.shell ? route;
          assert evalU280Shell.coyoteTwoStage.physical.units.shell ? validate;
          assert evalU280Shell.coyoteTwoStage.physical.units ? config_0;
          assert evalU280Shell.coyoteTwoStage.physical.units.config_0 ? finalize;
          assert evalV80Shell.coyoteTwoStage.kind == "shell";
          assert !evalV80Shell.coyoteTwoStage.physical.combineOptPlace;
          assert
            evalV80Shell.coyoteTwoStage.stageNames == [
              "synth"
              "dynamic"
              "bitgen"
            ];
          assert !(evalV80Shell.coyoteTwoStage.stages ? routed);
          assert evalV80Shell.coyoteTwoStage.stages ? synthesisAnalysisRaw;
          assert evalV80Shell.coyoteTwoStage.stages ? synthesisAnalysis;
          assert evalV80Shell.coyoteTwoStage.stages ? synthesisGate;
          assert !evalV80Shell.coyoteTwoStage.synthesisAnalysis.canonicalBuildDependency;
          assert evalV80Shell.coyoteTwoStage.synthesisAnalysis.policy.rejectSetupWnsBelow == -0.25;
          assert evalV80Shell.coyoteTwoStage.synthesisAnalysis.policy.passSetupWnsAtLeast == 0.75;
          assert evalV80Shell.coyoteTwoStage.synthesisAnalysis.policy.maximumLogicLevels == 12;
          assert evalV80Shell.coyoteTwoStage.synthesisAnalysis.policy.maxPaths == 64;
          assert evalV80Shell.coyoteTwoStage.synthesisAnalysis.policy.maxFanoutNets == 32;
          assert
            evalV80Shell.coyoteTwoStage.stages.synthesisAnalysisRaw.drvPath
            == evalV80ShellRetuned.coyoteTwoStage.stages.synthesisAnalysisRaw.drvPath;
          assert
            evalV80Shell.coyoteTwoStage.stages.synth.drvPath
            == evalV80ShellRetuned.coyoteTwoStage.stages.synth.drvPath;
          assert
            evalV80Shell.coyoteTwoStage.stages.synthesisAnalysis.drvPath
            != evalV80ShellRetuned.coyoteTwoStage.stages.synthesisAnalysis.drvPath;
          assert evalV80Shell.coyoteTwoStage.stages ? timingOracle;
          assert evalV80Shell.coyoteTwoStage.stages ? timingGate;
          assert !evalV80Shell.coyoteTwoStage.timingOracle.canonicalBuildDependency;
          assert evalV80Shell.coyoteTwoStage.timingOracle.policy.enforce;
          assert evalV80Shell.coyoteTwoStage.timingOracle.policy.rejectRqaBelow == 2;
          assert evalV80Shell.coyoteTwoStage.timingOracle.policy.passRqaAtLeast == 5;
          assert evalV80Shell.coyoteTwoStage.timingOracle.policy.maxPaths == 64;
          assert !evalV80Shell.coyoteTwoStage.enShellPblock;
          assert evalV80Shell.coyoteTwoStage.physical.units ? config_0;
          assert evalV80Shell.coyoteTwoStage.physical.units.config_0 ? finalize;
          assert !(evalV80Shell.coyoteTwoStage.physical.units ? shell);
          assert
            evalV80Shell.coyoteTwoStage.physical.units.config_0.link.drvPath
            == evalV80ShellRouteRetuned.coyoteTwoStage.physical.units.config_0.link.drvPath;
          assert
            evalV80Shell.coyoteTwoStage.physical.units.config_0.opt.drvPath
            == evalV80ShellRouteRetuned.coyoteTwoStage.physical.units.config_0.opt.drvPath;
          assert
            evalV80Shell.coyoteTwoStage.physical.units.config_0.place.drvPath
            == evalV80ShellRouteRetuned.coyoteTwoStage.physical.units.config_0.place.drvPath;
          assert
            evalV80Shell.coyoteTwoStage.physical.units.config_0.route.drvPath
            != evalV80ShellRouteRetuned.coyoteTwoStage.physical.units.config_0.route.drvPath;
          assert
            evalV80Shell.coyoteTwoStage.physical.units.config_0.validate.drvPath
            != evalV80ShellRouteRetuned.coyoteTwoStage.physical.units.config_0.validate.drvPath;
          assert evalU280App.coyoteTwoStage.kind == "app";
          assert evalU280App.coyoteTwoStage.physical.combineOptPlace;
          assert evalU280App.coyoteTwoStage.physical.stages.opt == null;
          assert evalU280App.coyoteTwoStage.shellPath == toString evalU280Shell;
          assert builtins.elem "-DBUILD_APP:STRING=1" evalU280App.coyoteTwoStage.appCmakeFlags;
          assert builtins.elem "-DSHELL_PATH=${evalU280Shell}" evalU280App.coyoteTwoStage.appCmakeFlags;
          assert evalV80App.coyoteTwoStage.kind == "app";
          assert !evalV80App.coyoteTwoStage.physical.combineOptPlace;
          assert evalV80App.coyoteTwoStage.shellPath == toString evalV80Shell;
          assert builtins.elem "-DEN_SHELL_PBLOCK:STRING=0" evalV80App.coyoteTwoStage.appCmakeFlags;
          assert evalV80App.coyoteTwoStage.physical.api == "coyote-nix.implementation-stage/v2";
          assert evalV80App.coyoteTwoStage.stages ? implementationInputs;
          assert evalV80App.coyoteTwoStage.stages ? link;
          assert evalV80App.coyoteTwoStage.stages ? opt;
          assert evalV80App.coyoteTwoStage.stages ? place;
          assert evalV80App.coyoteTwoStage.stages ? route;
          assert evalV80App.coyoteTwoStage.stages ? validate;
          assert
            evalV80App.coyoteTwoStage.stages.routed.drvPath
            == evalV80App.coyoteTwoStage.stages.validationGate.drvPath;
          assert
            evalV80App.coyoteTwoStage.stages.link.drvPath
            == evalV80AppRetuned.coyoteTwoStage.stages.link.drvPath;
          assert
            evalV80App.coyoteTwoStage.stages.opt.drvPath == evalV80AppRetuned.coyoteTwoStage.stages.opt.drvPath;
          assert
            evalV80App.coyoteTwoStage.stages.place.drvPath
            == evalV80AppRetuned.coyoteTwoStage.stages.place.drvPath;
          assert
            evalV80App.coyoteTwoStage.stages.route.drvPath
            != evalV80AppRetuned.coyoteTwoStage.stages.route.drvPath;
          assert
            evalV80App.coyoteTwoStage.stages.validate.drvPath
            != evalV80AppRetuned.coyoteTwoStage.stages.validate.drvPath;
          assert !invalidUnboundedPortfolioEval.success;
          assert !invalidRouteSelectionEval.success;
          assert
            evalV80AppPortfolio.coyoteTwoStage.physical.placementPortfolio.api
            == "coyote-nix.placement-portfolio/v1";
          assert evalV80AppPortfolio.coyoteTwoStage.physical.placementPortfolio.explicitRouteSelection;
          assert
            evalV80AppPortfolio.coyoteTwoStage.physical.placementPortfolio.routeCandidates == [ "balanced" ];
          assert
            builtins.attrNames evalV80AppPortfolio.coyoteTwoStage.stages.placementCandidates == [
              "balanced"
              "spread"
            ];
          assert evalV80AppPortfolio.coyoteTwoStage.stages.placementCandidates.balanced.route != null;
          assert evalV80AppPortfolio.coyoteTwoStage.stages.placementCandidates.balanced.validate != null;
          assert evalV80AppPortfolio.coyoteTwoStage.stages.placementCandidates.spread.route == null;
          assert evalV80AppPortfolio.coyoteTwoStage.stages.placementCandidates.spread.validate == null;
          assert
            evalV80AppPortfolio.coyoteTwoStage.stages.placementCandidates.balanced.place.drvPath
            != evalV80AppPortfolio.coyoteTwoStage.stages.placementCandidates.spread.place.drvPath;
          assert evalV80AppPortfolio.coyoteTwoStage.stages.placementRecommendation != null;
          assert !mismatchedAppBoardEval.success;
          pkgs.runCommand "two-stage-packages-eval" { } ''
            touch $out
          '';

        checks.two-stage-contract-unit =
          pkgs.runCommand "two-stage-contract-unit"
            {
              nativeBuildInputs = [ pkgs.jq ];
            }
            ''
              jq -e '
                .u280.shellStages == ["synth", "routed", "dynamic", "bitgen"]
                and .u280.shellPblock == true
                and .u280.shellBitstreams == [
                  "cyt_top.bit",
                  "shell_top.bin",
                  "config_0/vfpga_c0_0.bin"
                ]
                and .u280.appBitstreams == ["config_0/vfpga_c0_0.bin"]
                and .v80.shellStages == ["synth", "dynamic", "bitgen"]
                and .v80.shellPblock == false
                and .v80.shellBitstreams == [
                  "cyt_top.pdi",
                  "config_0/vfpga_c0_0.pdi"
                ]
                and .v80.appBitstreams == ["config_0/vfpga_c0_0.pdi"]
              ' ${twoStageContractFixture} >/dev/null
              touch $out
            '';

        checks.bitgen-completion-contract =
          pkgs.runCommand "bitgen-completion-contract"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.jq
              ];
            }
            ''
              mkdir -p fake-bin
              cat > fake-bin/vivado <<'EOF'
              #!${pkgs.bash}/bin/bash
              mkdir -p "$build_dir/bitstreams"
              case "$BITGEN_TEST_MODE" in
                success)
                  touch "$build_dir/bitstreams/cyt_top.bit" "$build_dir/bitstreams/complete"
                  exit 0
                  ;;
                cleanup-failure)
                  touch "$build_dir/bitstreams/cyt_top.bit" "$build_dir/bitstreams/complete"
                  exit 1
                  ;;
                artifact-only)
                  touch "$build_dir/bitstreams/cyt_top.bit"
                  exit 1
                  ;;
                no-marker-success)
                  touch "$build_dir/bitstreams/cyt_top.bit"
                  exit 0
                  ;;
                stale-failure)
                  exit 1
                  ;;
              esac
              exit 2
              EOF
              chmod +x fake-bin/vivado
              export PATH="$PWD/fake-bin:$PATH"
              run_case() {
                mode="$1"
                build_dir="$TMPDIR/$mode"
                export mode build_dir BITGEN_TEST_MODE="$mode"
                mkdir -p "$build_dir"
                : > "$build_dir/bitgen.tcl"
                bash -c ${pkgs.lib.escapeShellArg bitgenCompletionSnippet}
              }
              run_case success
              jq -e '.exitCode == 0 and .completionMarkerObserved and .anomaly == null' \
                "$TMPDIR/success/metadata/primary-tool.json" >/dev/null
              run_case cleanup-failure
              jq -e '.exitCode == 1 and .completionMarkerObserved and .anomaly == "post-completion-nonzero-exit"' \
                "$TMPDIR/cleanup-failure/metadata/primary-tool.json" >/dev/null
              if run_case artifact-only; then
                echo 'bitgen unexpectedly accepted an artifact without a completion marker' >&2
                exit 1
              fi
              if run_case no-marker-success; then
                echo 'bitgen unexpectedly accepted a successful exit without a completion marker' >&2
                exit 1
              fi
              mkdir -p "$TMPDIR/stale-failure/bitstreams"
              touch "$TMPDIR/stale-failure/bitstreams/cyt_top.bit" \
                "$TMPDIR/stale-failure/bitstreams/complete"
              if run_case stale-failure; then
                echo 'bitgen unexpectedly accepted stale artifacts and completion marker' >&2
                exit 1
              fi
              touch "$out"
            '';

        checks.implementation-stage-manifest-contract =
          pkgs.runCommand "implementation-stage-manifest-contract"
            {
              nativeBuildInputs = [
                pkgs.python3
                pkgs.jq
              ];
            }
            ''
              bash ${./tests/implementation-stage-manifest.sh} \
                ${./nix/tools/coyote-implementation-stage.py} \
                ${./tests/fixtures} \
                ${./nix/tools/coyote-incremental-reference.py}
              touch "$out"
            '';

        checks.placement-diagnosis-contract =
          pkgs.runCommand "placement-diagnosis-contract"
            {
              nativeBuildInputs = [
                pkgs.python3
                pkgs.jq
              ];
            }
            ''
              bash ${./tests/placement-diagnosis.sh} \
                ${./nix/tools/coyote-placement-diagnosis.py}
              touch "$out"
            '';

        checks.stage-execution-evidence =
          pkgs.runCommand "stage-execution-evidence-contract"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.cmake
                pkgs.coreutils
                pkgs.gawk
                pkgs.gnugrep
                pkgs.gnused
                pkgs.jq
                pkgs.time
              ];
            }
            ''
              export FDEV_NAME=fixture
              export COYOTE_NIX_HW_CORES=3
              export COYOTE_NIX_TIME=${pkgs.time}/bin/time
              export COYOTE_NIX_CHECK_TIMING_LOG=0
              export COYOTE_NIX_XILINX_SHARE_ROOT="$TMPDIR/xilinx"
              export COYOTE_NIX_XILINX_VERSION=fixture
              bash ${./tests/stage-execution-evidence.sh} \
                ${./nix/tools/run-coyote-hw-stage-build.sh}
              touch "$out"
            '';

        checks.two-stage-artifact-manifest-unit =
          pkgs.runCommand "two-stage-artifact-manifest-unit"
            {
              nativeBuildInputs = [ pkgs.jq ];
            }
            ''
              mkdir -p "$out/checkpoints/nested" "$out/bitstreams/config_0"
              printf 'checkpoint\n' > "$out/checkpoints/nested/file with spaces.dcp"
              printf 'partial\n' > "$out/bitstreams/config_0/vfpga.bin"
              ${artifactManifestSnippet}
              jq -e '
                length == 2
                and map(.path) == [
                  "checkpoints/nested/file with spaces.dcp",
                  "bitstreams/config_0/vfpga.bin"
                ]
                and all(.[]; .sha256 | test("^[0-9a-f]{64}$"))
              ' "$out/artifacts.json" >/dev/null
            '';

        checks.two-stage-generated-shell-syntax = pkgs.runCommand "two-stage-generated-shell-syntax" { } ''
          ${pkgs.lib.concatMapStringsSep "\n" (script: ''
            ${pkgs.bash}/bin/bash -n ${script}
          '') twoStagePhaseScripts}
          grep -F 'make synthesis_analysis' \
            ${phaseScript "v80-analysis-contract.sh" evalV80Shell.coyoteTwoStage.stages.synthesisAnalysisRaw.buildPhase} >/dev/null
          if grep -F '/nonexistent/external-static-marker' \
            ${phaseScript "v80-analysis-static-independence.sh" evalV80Shell.coyoteTwoStage.stages.synthesisAnalysisRaw.buildPhase} >/dev/null; then
            echo 'raw synthesis analysis unexpectedly depends on the external static checkpoint' >&2
            exit 1
          fi
          if grep -E '^[[:space:]]*make (synth|timing_oracle|app|bitgen)[[:space:]]*$' \
            ${phaseScript "v80-analysis-no-implementation.sh" evalV80Shell.coyoteTwoStage.stages.synthesisAnalysisRaw.buildPhase} >/dev/null; then
            echo 'raw synthesis analysis unexpectedly invokes a later build stage' >&2
            exit 1
          fi
          grep -F 'resident-shell-synth' \
            ${phaseScript "v80-synth-reuse-contract.sh" evalV80Shell.coyoteTwoStage.stages.synth.buildPhase} >/dev/null
          if grep -F 'synthesis-analysis-raw' \
            ${phaseScript "v80-synth-diagnostic-independence.sh" evalV80Shell.coyoteTwoStage.stages.synth.buildPhase} >/dev/null; then
            echo 'canonical shell synthesis unexpectedly depends on synthesized-shell analysis' >&2
            exit 1
          fi
          grep -F 'cp -a ' \
            ${phaseScript "v80-synth-preserve-checkpoint-times.sh" evalV80Shell.coyoteTwoStage.stages.synth.buildPhase} >/dev/null
          grep -F '.imported-stage-timestamp' \
            ${phaseScript "v80-synth-normalize-checkpoint-times.sh" evalV80Shell.coyoteTwoStage.stages.synth.buildPhase} >/dev/null
          if grep -F 'example-v80-shell-synthesis-analysis-gate' \
            ${phaseScript "v80-synth-policy-independence.sh" evalV80Shell.coyoteTwoStage.stages.synth.buildPhase} >/dev/null; then
            echo 'shell synthesis unexpectedly depends on synthesis classification policy' >&2
            exit 1
          fi
          if grep -F 'synthesis-analysis-gate' \
            ${phaseScript "v80-oracle-advisory-contract.sh" evalV80Shell.coyoteTwoStage.stages.timingOracle.buildPhase} >/dev/null; then
            echo 'timing oracle unexpectedly depends on synthesized-shell classification' >&2
            exit 1
          fi
          test -x ${pkgs.python3}/bin/python3
          u280_rqa_script=${phaseScript "u280-physical-rqa-safety.sh" evalU280Shell.coyoteTwoStage.physical.units.shell.place.buildPhase}
          grep -F 'chmod u+w "$build_dir/base.tcl" "$build_dir/physical_stage.tcl"' "$u280_rqa_script" >/dev/null
          grep -F 'patch-u280-vivado-2023.2-physical-stage.py' "$u280_rqa_script" >/dev/null
          mkdir generated-rqa-test
          cat > generated-rqa-test/base.tcl <<'EOF'
              set congestion_path "$report_dir/_congestion.rpt"
              set complexity_path "$report_dir/_complexity.rpt"
              set logic_levels_path "$report_dir/_logic_levels.rpt"
              set high_fanout_path "$report_dir/_high_fanout.rpt"
              set output_path "$report_dir/_diagnosis.json"
              set prefix "shell_"
              if {$phase in {opt place}} {
                  set utilization_path "$report_dir/_utilization.rpt"
                  set timing_path "$report_dir/_timing_summary.rpt"
                  set rqa_report "$report_dir/_qor_assessment.rpt"
                  report_qor_assessment
              }
              set unrouted ""
              set route_report "$report_dir/_route_status.rpt"
              if {$phase in {route validate}} {
              } elseif {$phase in {opt place}} {
              }
          EOF
          cat > generated-rqa-test/physical_stage.tcl <<'EOF'
              set phase "place"
              open_checkpoint $input_dcp
              switch -- $phase {
                  opt {
                      set directive "project"
                      if {$directive ne ""} { opt_design -directive $directive } else { opt_design }
                  }
                  place {
                      if {$place_directive ne ""} { place_design -directive $place_directive } else { place_design }
                  }
                  route {
                  }
              }
              if {$incremental_mode eq "reference" && $phase in {place route}} {
                  report_incremental_reuse
              }
              write_implementation_observations
              write_checkpoint -force $output_dcp
              close_project
          EOF
          chmod a-w generated-rqa-test/base.tcl generated-rqa-test/physical_stage.tcl
          chmod u+w generated-rqa-test/base.tcl generated-rqa-test/physical_stage.tcl
          ${pkgs.python3}/bin/python3 \
            ${./nix/tools/patch-u280-vivado-2023.2-physical-stage.py} \
            generated-rqa-test/base.tcl generated-rqa-test/physical_stage.tcl
          grep -F 'set prefix "shell_''${phase}"' generated-rqa-test/base.tcl >/dev/null
          grep -F 'if {0 && $phase in {opt place}} {' generated-rqa-test/base.tcl >/dev/null
          grep -F '"$report_dir/''${prefix}_timing_summary''${report_suffix}.rpt"' generated-rqa-test/base.tcl >/dev/null
          grep -F 'QoR Assessment unavailable: disabled for U280 under Vivado 2023.2' generated-rqa-test/base.tcl >/dev/null
          if grep -F '$report_dir/_' generated-rqa-test/base.tcl >/dev/null; then
            echo 'U280 physical report path lost its Tcl runtime prefix during CMake configuration' >&2
            exit 1
          fi
          awk '/^        place \{/ { copying = 1 } /^        route \{/ { copying = 0 } copying { print }' \
            generated-rqa-test/physical_stage.tcl > generated-rqa-test/place-case.tcl
          grep -F 'opt_design -directive $directive' generated-rqa-test/place-case.tcl >/dev/null
          grep -F 'if {$cfg(peer_backend) eq "aurora_qsfp1"} {' generated-rqa-test/physical_stage.tcl >/dev/null
          grep -F 'gt1_rxp_in[0] G53' generated-rqa-test/physical_stage.tcl >/dev/null
          grep -F 'reset_property PACKAGE_PIN $selected_port' generated-rqa-test/physical_stage.tcl >/dev/null
          grep -F 'gen_channel_container\[24\]' generated-rqa-test/physical_stage.tcl >/dev/null
          grep -F 'Expected exactly one Aurora channel' generated-rqa-test/physical_stage.tcl >/dev/null
          grep -F '3 GTYE4_CHANNEL_X0Y44 2 GTYE4_CHANNEL_X0Y45' generated-rqa-test/physical_stage.tcl >/dev/null
          test "$(grep -n 'write_checkpoint -force' generated-rqa-test/physical_stage.tcl | cut -d: -f1)" -lt \
            "$(grep -n 'write_implementation_observations' generated-rqa-test/physical_stage.tcl | cut -d: -f1)"
          if grep -F 'if {0 && $phase in {opt place}} {' \
            ${phaseScript "v80-physical-rqa-availability.sh" evalV80Shell.coyoteTwoStage.physical.units.config_0.opt.buildPhase} >/dev/null; then
            echo 'physical QoR Assessment was unexpectedly disabled for V80' >&2
            exit 1
          fi
          for script in \
            ${phaseScript "u280-physical-diagnostic-independence.sh" evalU280Shell.coyoteTwoStage.physical.units.shell.link.buildPhase} \
            ${phaseScript "v80-physical-diagnostic-independence.sh" evalV80Shell.coyoteTwoStage.physical.units.config_0.link.buildPhase}; do
            if grep -E '(synthesis-analysis|timing-oracle)-gate' "$script" >/dev/null; then
              echo "canonical implementation unexpectedly depends on a predictive diagnostic: $script" >&2
              exit 1
            fi
          done
          if grep -F '/nonexistent/external-static-marker' \
            ${phaseScript "v80-synth-static-independence.sh" evalV80Shell.coyoteTwoStage.stages.synth.buildPhase} >/dev/null; then
            echo 'shell synthesis unexpectedly depends on the external static checkpoint' >&2
            exit 1
          fi
          grep -F '/nonexistent/external-static-marker' \
            ${phaseScript "v80-oracle-static-contract.sh" evalV80Shell.coyoteTwoStage.stages.timingOracle.buildPhase} >/dev/null
          grep -F '.postPlace != null' \
            ${phaseScript "v80-oracle-placement-artifact-contract.sh" evalV80Shell.coyoteTwoStage.stages.timingOracle.installPhase} >/dev/null
          grep -F 'bitstreams/complete' \
            ${phaseScript "v80-shell-bitgen-completion-contract.sh" evalV80Shell.buildPhase} >/dev/null
          grep -F 'bitstreams/complete' \
            ${phaseScript "u280-app-bitgen-completion-contract.sh" evalU280App.buildPhase} >/dev/null
          grep -F 'IMPLEMENTATION_TELEMETRY_PATH' \
            ${phaseScript "v80-route-telemetry-contract.sh" evalV80Shell.coyoteTwoStage.stages.route.buildPhase} >/dev/null
          grep -F 'reports/config_0/shell_route_physical_c0.json' \
            ${phaseScript "v80-route-report-layout.sh" evalV80Shell.coyoteTwoStage.stages.route.buildPhase} >/dev/null
          grep -F 'metadata/primary-tool.json' \
            ${phaseScript "v80-image-primary-tool-contract.sh" evalV80Shell.installPhase} >/dev/null
          grep -F 'metadata/execution.json' \
            ${phaseScript "v80-route-execution-contract.sh" evalV80Shell.coyoteTwoStage.stages.route.installPhase} >/dev/null
          touch $out
        '';

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            shellcheck
            nixfmt-rfc-style
          ];
        };

        formatter = pkgs.nixfmt-rfc-style;
      }
    )
    // {
      lib = coyoteNixLib;
    };
}
