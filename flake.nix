{
  description = "Reusable Nix tooling for Coyote FPGA development";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    coyote = {
      url = "github:taugoust/Coyote/v80-opt-report-production";
      flake = false;
    };
    coyoteDeltaBase = {
      url = "github:taugoust/Coyote/d0e293778b2e14c3b69c3e9e6295b10dabafe24e";
      flake = false;
    };
    coyoteDeltaCandidate = {
      url = "github:taugoust/Coyote/a2ea6a76e93e526fc264d4a8eaa11291fc2f33e8";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      coyote,
      coyoteDeltaBase,
      coyoteDeltaCandidate,
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
        coyoteDeltaPatch = ./tests/fixtures/coyote-d0e293-a2ea6a76.patch;
        coyoteDeltaArguments = {
          inherit pkgs;
          baseSource = coyoteDeltaBase;
          candidateSource = coyoteDeltaCandidate;
          patch = coyoteDeltaPatch;
          baseSourceId = "06d94332001897aa79cf950e18f6fa98315c38d3c10fe41678f1f5e68fc902b0";
          candidateSourceId = "876c2cfc1b8914a1791143eb5a307658eed59a46a44bcb340a98d42e47034706";
          patchSha256 = "0d0b4e254b6de98df76eda04543f7c10374957dda9d7812e087dae81e879b43e";
          changedPaths = [
            "scripts/cr_prjcts/cr_user.tcl.in"
            "tests/user_project_source_management/template_contract.tcl"
          ];
          policy = "user-project-generation";
        };
        verifiedCoyoteUserProjectDelta = coyoteNixLib.mkCoyoteSourceDelta coyoteDeltaArguments;
        invalidCoyoteDeltaRevisionEval = builtins.tryEval (
          (coyoteNixLib.mkCoyoteSourceDelta (
            coyoteDeltaArguments
            // {
              baseRevision = coyoteDeltaCandidate.rev;
            }
          )).drvPath
        );
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
              finalEnablePr = false;
            };
            v80 = {
              xilinxVersion = "site-selected-v80-build-version";
              staticBuild = true;
              routedCmakeFlags = [ "-DIMPLEMENTATION_ROUTE_DIRECTIVE:STRING=AggressiveExplore" ];
            };
          };
        };
        evalReusedV80Synthesis = coyoteNixLib.mkCoyoteBoardPackages {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = ./.;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pnamePrefix = "example-v80-candidate";
          projectName = "example-project";
          boards.v80 = {
            xilinxVersion = "site-selected-v80-build-version";
            staticBuild = true;
            synthesisPackage = evalBoardPackages."example-v80-synth";
          };
        };
        evalImportedU280Static = coyoteNixLib.mkCoyoteBoardPackages {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = ./.;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pnamePrefix = "example-imported";
          projectName = "example-project";
          boards.u280 = {
            xilinxVersion = "2023.2";
            staticCheckpoint = {
              stage = ./.;
              manifestId = builtins.concatStringsSep "" (builtins.genList (_: "1") 64);
              checkpointSha256 = builtins.concatStringsSep "" (builtins.genList (_: "2") 64);
              coyoteSourceId = builtins.hashString "sha256" (toString ./.);
              fixedRouteNets = 7;
            };
          };
        };
        invalidLegacyU280StaticEval = builtins.tryEval (
          (coyoteNixLib.mkCoyoteBoardPackages {
            inherit pkgs;
            tools = evalTools;
            coyoteRoot = ./.;
            hwSource = ./.;
            xilinxShareRoot = "/nonexistent/xilinx";
            pnamePrefix = "invalid-legacy";
            boards.u280 = {
              xilinxVersion = "2023.2";
              staticCheckpointDirectory = "/nonexistent/unchecked-static";
            };
          })."invalid-legacy-u280-static".drvPath
        );
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
        evalDeltaU280Shell = coyoteNixLib.mkCoyoteShellPackage {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = coyoteDeltaBase;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pname = "example-delta-u280-shell";
          board = "u280";
          xilinxVersion = "2023.2";
        };
        evalDeltaU280App = coyoteNixLib.mkCoyoteAppPackage {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = coyoteDeltaBase;
          userProjectCoyoteSource = verifiedCoyoteUserProjectDelta;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pname = "example-delta-u280-app";
          shellPackage = evalDeltaU280Shell;
        };
        evalDeltaV80Shell = coyoteNixLib.mkCoyoteShellPackage {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = coyoteDeltaBase;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pname = "example-delta-v80-shell";
          board = "v80";
          xilinxVersion = "site-selected-v80-build-version";
        };
        invalidDeltaV80AppEval = builtins.tryEval (
          (coyoteNixLib.mkCoyoteAppPackage {
            inherit pkgs;
            tools = evalTools;
            coyoteRoot = coyoteDeltaBase;
            userProjectCoyoteSource = verifiedCoyoteUserProjectDelta;
            hwSource = ./.;
            xilinxShareRoot = "/nonexistent/xilinx";
            pname = "invalid-delta-v80-app";
            shellPackage = evalDeltaV80Shell;
          }).drvPath
        );
        invalidMismatchedCoyoteAppEval = builtins.tryEval (
          (coyoteNixLib.mkCoyoteAppPackage {
            inherit pkgs;
            tools = evalTools;
            coyoteRoot = coyoteDeltaCandidate;
            hwSource = ./.;
            xilinxShareRoot = "/nonexistent/xilinx";
            pname = "invalid-mismatched-coyote-app";
            shellPackage = evalDeltaU280Shell;
          }).drvPath
        );
        unverifiedCoyoteSource = pkgs.runCommand "unverified-coyote-source" { } ''
          mkdir -p "$out"
        '';
        invalidUnverifiedDeltaAppEval = builtins.tryEval (
          (coyoteNixLib.mkCoyoteAppPackage {
            inherit pkgs;
            tools = evalTools;
            coyoteRoot = coyoteDeltaBase;
            userProjectCoyoteSource = unverifiedCoyoteSource;
            hwSource = ./.;
            xilinxShareRoot = "/nonexistent/xilinx";
            pname = "invalid-unverified-delta-app";
            shellPackage = evalDeltaU280Shell;
          }).drvPath
        );
        evalDeltaImportedU280Static = coyoteNixLib.mkCoyoteBoardPackages {
          inherit pkgs;
          tools = evalTools;
          coyoteRoot = coyoteDeltaBase;
          userProjectCoyoteSource = verifiedCoyoteUserProjectDelta;
          hwSource = ./.;
          xilinxShareRoot = "/nonexistent/xilinx";
          pnamePrefix = "example-delta-imported";
          projectName = "example-project";
          boards.u280 = {
            xilinxVersion = "2023.2";
            staticCheckpoint = {
              stage = ./.;
              manifestId = builtins.concatStringsSep "" (builtins.genList (_: "1") 64);
              checkpointSha256 = builtins.concatStringsSep "" (builtins.genList (_: "2") 64);
              coyoteSourceId = coyoteDeltaArguments.baseSourceId;
              fixedRouteNets = 7;
            };
          };
        };
        invalidDeltaWithoutImportedStaticEval = builtins.tryEval (
          (coyoteNixLib.mkCoyoteBoardPackages {
            inherit pkgs;
            tools = evalTools;
            coyoteRoot = coyoteDeltaBase;
            userProjectCoyoteSource = verifiedCoyoteUserProjectDelta;
            hwSource = ./.;
            xilinxShareRoot = "/nonexistent/xilinx";
            pnamePrefix = "invalid-delta-no-import";
            boards.u280.xilinxVersion = "2023.2";
          })."invalid-delta-no-import-u280".drvPath
        );
        invalidDeltaMismatchedBaseEval = builtins.tryEval (
          (coyoteNixLib.mkCoyoteBoardPackages {
            inherit pkgs;
            tools = evalTools;
            coyoteRoot = ./.;
            userProjectCoyoteSource = verifiedCoyoteUserProjectDelta;
            hwSource = ./.;
            xilinxShareRoot = "/nonexistent/xilinx";
            pnamePrefix = "invalid-delta-base";
            boards.u280 = {
              xilinxVersion = "2023.2";
              staticCheckpoint = {
                stage = ./.;
                manifestId = builtins.concatStringsSep "" (builtins.genList (_: "1") 64);
                checkpointSha256 = builtins.concatStringsSep "" (builtins.genList (_: "2") 64);
                coyoteSourceId = builtins.hashString "sha256" (toString ./.);
                fixedRouteNets = 7;
              };
            };
          })."invalid-delta-base-u280".drvPath
        );
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
          (phaseScript "u280-app-elaboration-build-phase.sh" evalU280App.coyoteTwoStage.stages.elaboration.buildPhase)
          (phaseScript "u280-app-elaboration-install-phase.sh" evalU280App.coyoteTwoStage.stages.elaboration.installPhase)
          (phaseScript "u280-app-synth-build-phase.sh" evalU280App.coyoteTwoStage.stages.synth.buildPhase)
          (phaseScript "u280-app-link-build-phase.sh" evalU280App.coyoteTwoStage.stages.link.buildPhase)
          (phaseScript "u280-app-link-install-phase.sh" evalU280App.coyoteTwoStage.stages.link.installPhase)
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
          (phaseScript "v80-app-link-install-phase.sh" evalV80App.coyoteTwoStage.stages.link.installPhase)
          (phaseScript "v80-app-route-build-phase.sh" evalV80App.coyoteTwoStage.stages.route.buildPhase)
          (phaseScript "v80-app-build-phase.sh" evalV80App.buildPhase)
          (phaseScript "v80-app-install-phase.sh" evalV80App.installPhase)
        ];
      in
      {
        checks.coyote-source-delta =
          assert coyoteNixLib ? mkCoyoteSourceDelta;
          assert !invalidCoyoteDeltaRevisionEval.success;
          assert verifiedCoyoteUserProjectDelta.coyoteSourceDelta.kind == "verified-coyote-source-delta";
          assert verifiedCoyoteUserProjectDelta.coyoteSourceDelta.failClosed;
          assert
            verifiedCoyoteUserProjectDelta.coyoteSourceDelta.base.sourceId == coyoteDeltaArguments.baseSourceId;
          assert
            verifiedCoyoteUserProjectDelta.coyoteSourceDelta.candidate.sourceId
            == coyoteDeltaArguments.candidateSourceId;
          pkgs.runCommand "coyote-source-delta-check"
            {
              nativeBuildInputs = [
                pkgs.diffutils
                pkgs.git
                pkgs.jq
                pkgs.python3
              ];
            }
            ''
              delta_tool=${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.verificationTool}
              delta_proof=${verifiedCoyoteUserProjectDelta}
              verify_proof() {
                python3 "$delta_tool" verify \
                  --base-source ${coyoteDeltaBase} \
                  --candidate-source ${coyoteDeltaCandidate} \
                  --patch ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.patch.path} \
                  --base-source-id ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.base.sourceId} \
                  --candidate-source-id ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.candidate.sourceId} \
                  --base-revision ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.base.revision} \
                  --candidate-revision ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.candidate.revision} \
                  --patch-sha256 ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.patch.sha256} \
                  --policy ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.policy} \
                  --policy-id ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.policyId} \
                  --delta-contract-id ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.contractId} \
                  ${
                    pkgs.lib.concatMapStringsSep " \\\n                  " (
                      path: "--changed-path ${pkgs.lib.escapeShellArg path}"
                    ) verifiedCoyoteUserProjectDelta.coyoteSourceDelta.patch.changedPaths
                  } \
                  --proof "$1"
              }
              expect_rejection() {
                label="$1"
                shift
                if "$@" >"$TMPDIR/$label.stdout" 2>"$TMPDIR/$label.stderr"; then
                  echo "ERROR: source-delta verifier accepted $label" >&2
                  exit 1
                fi
                grep -F 'ERROR:' "$TMPDIR/$label.stderr" >/dev/null
              }

              verify_proof "$delta_proof"
              diff --no-dereference --recursive ${coyoteDeltaCandidate}/ "$delta_proof/source/"
              jq -e '
                .failClosed == true
                and .outcome == "accepted"
                and .base.revision == "d0e293778b2e14c3b69c3e9e6295b10dabafe24e"
                and .candidate.revision == "a2ea6a76e93e526fc264d4a8eaa11291fc2f33e8"
                and [.changedPaths[].path] == [
                  "scripts/cr_prjcts/cr_user.tcl.in",
                  "tests/user_project_source_management/template_contract.tcl"
                ]
                and (.treeManifest.sha256 | test("^[0-9a-f]{64}$"))
                and (.contractId | test("^[0-9a-f]{64}$"))
                and (.policy.id | test("^[0-9a-f]{64}$"))
              ' "$delta_proof/metadata/delta.json" >/dev/null
              jq -e '
                .api == "coyote-nix.coyote-source-delta-completion/v1"
                and .failClosed == true
                and .outcome == "accepted"
                and .deltaContractId == "${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.contractId}"
              ' "$delta_proof/metadata/complete.json" >/dev/null

              cp -a "$delta_proof" "$TMPDIR/tampered-source"
              chmod -R u+w "$TMPDIR/tampered-source"
              printf '\nsource tamper\n' >> \
                "$TMPDIR/tampered-source/source/scripts/cr_prjcts/cr_user.tcl.in"
              expect_rejection tampered-source verify_proof "$TMPDIR/tampered-source"

              cp -a "$delta_proof" "$TMPDIR/unexpected-entry"
              chmod -R u+w "$TMPDIR/unexpected-entry"
              : > "$TMPDIR/unexpected-entry/uncontracted"
              expect_rejection unexpected-proof-entry verify_proof "$TMPDIR/unexpected-entry"

              cp ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.patch.path} \
                "$TMPDIR/tampered.patch"
              chmod u+w "$TMPDIR/tampered.patch"
              printf '\n# tamper\n' >> "$TMPDIR/tampered.patch"
              expect_rejection tampered-patch \
                python3 "$delta_tool" verify \
                  --base-source ${coyoteDeltaBase} \
                  --candidate-source ${coyoteDeltaCandidate} \
                  --patch "$TMPDIR/tampered.patch" \
                  --base-source-id ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.base.sourceId} \
                  --candidate-source-id ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.candidate.sourceId} \
                  --base-revision ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.base.revision} \
                  --candidate-revision ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.candidate.revision} \
                  --patch-sha256 ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.patch.sha256} \
                  --policy ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.policy} \
                  --policy-id ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.policyId} \
                  --delta-contract-id ${verifiedCoyoteUserProjectDelta.coyoteSourceDelta.contractId} \
                  ${
                    pkgs.lib.concatMapStringsSep " \\\n                  " (
                      path: "--changed-path ${pkgs.lib.escapeShellArg path}"
                    ) verifiedCoyoteUserProjectDelta.coyoteSourceDelta.patch.changedPaths
                  } \
                  --proof "$delta_proof"

              touch "$out"
            '';

        checks.coyote-source-delta-package-api =
          assert !invalidDeltaV80AppEval.success;
          assert !invalidMismatchedCoyoteAppEval.success;
          assert !invalidUnverifiedDeltaAppEval.success;
          assert !invalidDeltaWithoutImportedStaticEval.success;
          assert !invalidDeltaMismatchedBaseEval.success;
          assert evalDeltaU280App.coyoteTwoStage.coyoteSource == toString coyoteDeltaBase;
          assert
            evalDeltaU280App.coyoteTwoStage.effectiveUserProjectCoyoteSource
            == toString verifiedCoyoteUserProjectDelta.coyoteSourceDelta.source;
          assert
            evalDeltaU280App.coyoteTwoStage.coyoteSourceDelta.contractId
            == verifiedCoyoteUserProjectDelta.coyoteSourceDelta.contractId;
          assert
            evalDeltaU280App.coyoteTwoStage.physical.linkIntegrity.api
            == "coyote-nix.protected-static-integrity/v1";
          assert evalDeltaU280App.coyoteTwoStage.physical.linkIntegrity.failClosed;
          assert
            evalDeltaU280App.coyoteTwoStage.stages.elaboration.coyoteBuildSource.baseSource
            == toString coyoteDeltaBase;
          assert
            evalDeltaU280App.coyoteTwoStage.stages.elaboration.coyoteBuildSource.effectiveSource
            == toString verifiedCoyoteUserProjectDelta.coyoteSourceDelta.source;
          assert
            evalDeltaImportedU280Static."example-delta-imported-u280-static".coyoteStaticCheckpoint.coyoteSourceId
            == coyoteDeltaArguments.baseSourceId;
          assert
            evalDeltaImportedU280Static."example-delta-imported-u280-elaboration".coyoteBuildSource.coyoteSourceDeltaId
            == verifiedCoyoteUserProjectDelta.coyoteSourceDelta.contractId;
          assert
            evalDeltaImportedU280Static."example-delta-imported-u280-synth".coyoteBuildSource.effectiveSource
            == toString verifiedCoyoteUserProjectDelta.coyoteSourceDelta.source;
          pkgs.runCommand "coyote-source-delta-package-api"
            {
              nativeBuildInputs = [ pkgs.gnugrep ];
            }
            ''
              app_elaboration=${phaseScript "delta-app-elaboration.sh" evalDeltaU280App.coyoteTwoStage.stages.elaboration.buildPhase}
              app_link=${phaseScript "delta-app-link.sh" evalDeltaU280App.coyoteTwoStage.stages.link.buildPhase}
              app_place=${phaseScript "delta-app-place.sh" evalDeltaU280App.coyoteTwoStage.stages.place.buildPhase}
              app_route=${phaseScript "delta-app-route.sh" evalDeltaU280App.coyoteTwoStage.stages.route.buildPhase}
              integrated_elaboration=${
                phaseScript "delta-integrated-elaboration.sh"
                  evalDeltaImportedU280Static."example-delta-imported-u280-elaboration".buildPhase
              }
              integrated_routed=${
                phaseScript "delta-integrated-routed.sh"
                  evalDeltaImportedU280Static."example-delta-imported-u280-routed".buildPhase
              }
              integrated_final=${
                phaseScript "delta-integrated-final.sh"
                  evalDeltaImportedU280Static."example-delta-imported-u280".buildPhase
              }

              for script in "$app_elaboration" "$app_link" "$app_place" "$app_route" \
                "$integrated_elaboration" "$integrated_routed" "$integrated_final"; do
                grep -F 'coyote-source-delta.py' "$script" >/dev/null
                grep -F ' verify ' "$script" >/dev/null
              done
              for descriptor in \
                "link:$app_link" \
                "place:$app_place" \
                "route:$app_route"; do
                phase="''${descriptor%%:*}"
                script="''${descriptor#*:}"
                grep -F 'coyote-protected-static-integrity.tcl' "$script" >/dev/null
                grep -F "source-delta-$phase" "$script" >/dev/null
              done
              grep -F 'reports/source-delta-link' "$integrated_routed" >/dev/null
              grep -F 'reports/source-delta-place' "$integrated_routed" >/dev/null
              grep -F 'reports/source-delta-route' "$integrated_routed" >/dev/null
              grep -F 'routed stage lacks $phase protected-static integrity evidence' \
                "$integrated_final" >/dev/null
              touch "$out"
            '';

        checks.coyote-app-link-integrity = defaultCoyoteSourceChecks.appLinkIntegrityContract;
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

        checks.hot-reset-multifunction = pkgs.runCommand "hot-reset-multifunction-check" { } ''
          bash ${./tests/hot-reset-multifunction.sh} ${./nix/tools/hot-reset.sh}
          touch $out
        '';

        checks.u280-app-elaboration-contract =
          pkgs.runCommand "u280-app-elaboration-contract"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.gawk
                pkgs.tcl
              ];
            }
            ''
              cd ${./.}
              bash tests/app-elaboration.sh nix/tools/coyote-app-elaboration.tcl
              touch "$out"
            '';

        checks.protected-static-integrity =
          pkgs.runCommand "protected-static-integrity-contract"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.jq
                pkgs.tcl
              ];
            }
            ''
              cd "$TMPDIR"
              tclsh ${./tests/protected-static-integrity.tcl} \
                ${./nix/tools/coyote-protected-static-integrity.tcl}
              gate="$TMPDIR/protected-static-integrity-fixture/gate.json"
              rejected="$TMPDIR/protected-static-integrity-fixture/rejected-gate.json"
              jq -e '
                .schemaVersion == 1
                and .api == "coyote-nix.protected-static-integrity/v1"
                and .kind == "coyote-protected-static-integrity"
                and .failClosed == true
                and .outcome == "accepted"
                and .phase == "route"
                and .partitionPaths == ["inst_shell"]
                and .partitionPins.identical == true
                and .partitionPins.reference == .partitionPins.candidate
                and .partitionPins.reference.objectCount == 2
                and .protectedStatic.placement.identical == true
                and .protectedStatic.placement.reference.objectCount == 2
                and .protectedStatic.routing.identical == true
                and .protectedStatic.routing.reference.objectCount == 2
                and (.evidence | length) == 6
                and .reasons == []
              ' "$gate" >/dev/null
              jq -e '
                .failClosed == true
                and .outcome == "rejected"
                and .partitionPins.identical == false
                and (.reasons | length) > 0
              ' "$rejected" >/dev/null
              while IFS=$'\t' read -r path expected; do
                test "$(sha256sum "$TMPDIR/protected-static-integrity-fixture/$path" | cut -d' ' -f1)" = \
                  "$expected"
              done < <(jq -r '.evidence[] | [.path, .sha256] | @tsv' "$gate")
              touch "$out"
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

        checks.u280-static-checkpoint-import =
          pkgs.runCommand "u280-static-checkpoint-import-check"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.jq
                pkgs.python3
              ];
            }
            ''
              cd ${./.}
              bash tests/u280-static-checkpoint-import.sh \
                nix/tools/import-u280-static-checkpoint.py \
                ${./nix/tools/coyote-implementation-stage.py}
              touch "$out"
            '';

        checks.board-packages-eval =
          assert
            evalReusedV80Synthesis."example-v80-candidate-v80-synth" == evalBoardPackages."example-v80-synth";
          assert !invalidLegacyU280StaticEval.success;
          assert
            evalImportedU280Static."example-imported-u280-static".coyoteStaticCheckpoint == {
              api = "coyote-nix.u280-static-checkpoint/v1";
              failClosed = true;
              board = "u280";
              architecture = "ultrascale_plus";
              part = "xcu280-fsvh2892-2L-e";
              toolVersion = "2023.2";
              sourceStage = toString ./.;
              manifestId = builtins.concatStringsSep "" (builtins.genList (_: "1") 64);
              checkpointSha256 = builtins.concatStringsSep "" (builtins.genList (_: "2") 64);
              coyoteSourceId = builtins.hashString "sha256" (toString ./.);
              fixedRouteNets = 7;
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
          assert
            evalBoardPackages."example-u280-elaboration".coyoteAppElaboration.api
            == "coyote-nix.app-elaboration/v1";
          assert !evalBoardPackages."example-u280-elaboration".coyoteAppElaboration.buildApp;
          assert evalBoardPackages."example-u280-elaboration".coyoteAppElaboration.buildShell;
          assert evalBoardPackages."example-u280-elaboration".coyoteAppElaboration.rtlOnly;
          assert
            builtins.attrNames evalBoardPackages == [
              "example-u280"
              "example-u280-elaboration"
              "example-u280-routed"
              "example-u280-sim"
              "example-u280-static"
              "example-u280-synth"
              "example-v80"
              "example-v80-routed"
              "example-v80-synth"
            ];
          pkgs.runCommand "board-packages-eval" { } ''
            cat > synth-build-phase <<'EOF'
            ${builtins.unsafeDiscardStringContext evalBoardPackages."example-v80-synth".buildPhase}
            EOF
            cat > routed-build-phase <<'EOF'
            ${builtins.unsafeDiscardStringContext evalBoardPackages."example-v80-routed".buildPhase}
            EOF
            cat > u280-elaboration-build-phase <<'EOF'
            ${builtins.unsafeDiscardStringContext evalBoardPackages."example-u280-elaboration".buildPhase}
            EOF
            cat > u280-synth-build-phase <<'EOF'
            ${builtins.unsafeDiscardStringContext evalBoardPackages."example-u280-synth".buildPhase}
            EOF
            cat > u280-final-build-phase <<'EOF'
            ${builtins.unsafeDiscardStringContext evalBoardPackages."example-u280".buildPhase}
            EOF
            cat > u280-static-import-build-phase <<'EOF'
            ${builtins.unsafeDiscardStringContext
              evalImportedU280Static."example-imported-u280-static".buildCommand
            }
            EOF
            if grep -F 'IMPLEMENTATION_ROUTE_DIRECTIVE' synth-build-phase; then
              echo 'route-only CMake flags leaked into V80 synthesis' >&2
              exit 1
            fi
            grep -F 'checkpoints/static/static_synthed.dcp' synth-build-phase >/dev/null
            grep -F 'IMPLEMENTATION_ROUTE_DIRECTIVE:STRING=AggressiveExplore' \
              routed-build-phase >/dev/null
            grep -F 'make project' u280-elaboration-build-phase >/dev/null
            grep -F 'coyote-app-elaboration.tcl' u280-elaboration-build-phase >/dev/null
            if grep -E '^[[:space:]]*make (synth|shell|app|bitgen)[[:space:]]*$' \
              u280-elaboration-build-phase >/dev/null; then
              echo 'production U280 elaboration unexpectedly invokes synthesis or implementation' >&2
              exit 1
            fi
            grep -F 'example-u280-elaboration-0.1.0' u280-synth-build-phase >/dev/null
            grep -F 'expected_en_pr="0"' u280-final-build-phase >/dev/null
            grep -F 'generated base.tcl has no canonical cfg(en_pr) assignment' \
              u280-final-build-phase >/dev/null
            grep -F 'import-u280-static-checkpoint.py' u280-static-import-build-phase >/dev/null
            grep -E -- '--implementation-stage-tool /nix/store/[0-9a-z]{32}-coyote-implementation-stage\.py' \
              u280-static-import-build-phase >/dev/null
            if grep -F -- '--implementation-stage-tool /nix/store/coyote-implementation-stage.py' \
              u280-static-import-build-phase; then
              echo 'static importer referenced a bare implementation-stage store path' >&2
              exit 1
            fi
            grep -F -- '--fixed-route-nets' u280-static-import-build-phase >/dev/null
            grep -F -- '--reconfigurable-cell inst_shell' u280-static-import-build-phase >/dev/null
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
          assert evalU280Shell.coyoteTwoStage.physical.strictSignoff.required;
          assert evalU280Shell.coyoteTwoStage.physical.strictSignoff.classification == null;
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
          assert
            evalU280App.coyoteTwoStage.stageNames == [
              "elaboration"
              "synth"
              "app-route"
              "bitgen"
            ];
          assert evalU280App.coyoteTwoStage.elaboration.enabled;
          assert evalU280App.coyoteTwoStage.elaboration.canonicalBuildDependency;
          assert
            evalU280App.coyoteTwoStage.stages.elaboration.coyoteAppElaboration.api
            == "coyote-nix.app-elaboration/v1";
          assert evalU280App.coyoteTwoStage.stages.elaboration.coyoteAppElaboration.rtlOnly;
          assert evalU280App.coyoteTwoStage.physical.linkIntegrity.api == "coyote-nix.app-link-integrity/v1";
          assert evalU280App.coyoteTwoStage.physical.linkIntegrity.failClosed;
          assert evalU280App.coyoteTwoStage.physical.combineOptPlace;
          assert evalU280App.coyoteTwoStage.physical.stages.opt == null;
          assert evalU280App.coyoteTwoStage.shellPath == toString evalU280Shell;
          assert builtins.elem "-DBUILD_APP:STRING=1" evalU280App.coyoteTwoStage.appCmakeFlags;
          assert builtins.elem "-DSHELL_PATH=${evalU280Shell}" evalU280App.coyoteTwoStage.appCmakeFlags;
          assert evalV80App.coyoteTwoStage.kind == "app";
          assert
            evalV80App.coyoteTwoStage.stageNames == [
              "synth"
              "app-route"
              "bitgen"
            ];
          assert !evalV80App.coyoteTwoStage.elaboration.enabled;
          assert !evalV80App.coyoteTwoStage.elaboration.canonicalBuildDependency;
          assert evalV80App.coyoteTwoStage.stages.elaboration == null;
          assert !evalV80App.coyoteTwoStage.physical.combineOptPlace;
          assert evalV80App.coyoteTwoStage.shellPath == toString evalV80Shell;
          assert builtins.elem "-DEN_SHELL_PBLOCK:STRING=0" evalV80App.coyoteTwoStage.appCmakeFlags;
          assert evalV80App.coyoteTwoStage.physical.api == "coyote-nix.implementation-stage/v2";
          assert evalV80App.coyoteTwoStage.physical.strictSignoff.required;
          assert
            evalV80App.coyoteTwoStage.physical.strictSignoff.classificationApi
            == "coyote-nix.strict-signoff-classification/v1";
          assert
            evalV80App.coyoteTwoStage.physical.linkIntegrity.partitionPinManifest
            == "reports/config_0/app_link_partition_pins_c0.json";
          assert
            evalV80App.coyoteTwoStage.physical.linkIntegrity.summary
            == "reports/config_0/app_link_integrity_c0.json";
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

        checks.strict-signoff-report-generation =
          pkgs.runCommand "strict-signoff-report-generation-contract"
            {
              nativeBuildInputs = [
                pkgs.jq
                pkgs.python3
                pkgs.tcl
              ];
            }
            ''
              bash ${./tests/strict-signoff-report-generation.sh} \
                ${./nix/tools/coyote-signoff-reports.tcl} \
                ${./nix/tools/coyote-strict-signoff.py} \
                ${./tests/fixtures/strict-signoff}
              touch "$out"
            '';

        checks.strict-signoff-gate =
          pkgs.runCommand "strict-signoff-gate-contract"
            {
              nativeBuildInputs = [
                pkgs.jq
                pkgs.python3
              ];
            }
            ''
              bash ${./tests/strict-signoff-gate.sh} \
                ${./nix/tools/coyote-strict-signoff.py} \
                ${./nix/tools/coyote-implementation-stage.py} \
                ${./tests/fixtures/strict-signoff}
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

        checks.timing-policy-propagation =
          pkgs.runCommand "timing-policy-propagation-contract"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.cmake
                pkgs.coreutils
                pkgs.findutils
                pkgs.gawk
                pkgs.gnugrep
                pkgs.gnused
                pkgs.jq
                pkgs.tcl
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
              bash ${./tests/timing-policy-propagation.sh} \
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
          mkdir generated-current-rqa-test
          cat > generated-current-rqa-test/base.tcl <<'EOF'
              set output_path [file join $report_dir [format "%s_diagnosis%s.json" $prefix $report_suffix]]
              if {$phase eq "validate"} {
                  set prefix "shell"
              } else {
                  set prefix [format "shell_%s" $phase]
              }
              set timing_path [file join $report_dir [format "%s_timing_summary%s.rpt" $prefix $report_suffix]]
              if {$phase in {opt place}} {
                  set rqa_report [file join $report_dir [format "%s_qor_assessment%s.rpt" $prefix $report_suffix]]
                  report_qor_assessment
              }
              set unrouted ""
          EOF
          cp generated-rqa-test/physical_stage.tcl generated-current-rqa-test/physical_stage.tcl
          ${pkgs.python3}/bin/python3 \
            ${./nix/tools/patch-u280-vivado-2023.2-physical-stage.py} \
            generated-current-rqa-test/base.tcl generated-current-rqa-test/physical_stage.tcl
          grep -F 'if {0 && $phase in {opt place}} {' generated-current-rqa-test/base.tcl >/dev/null
          grep -F 'QoR Assessment unavailable: disabled for U280 under Vivado 2023.2' \
            generated-current-rqa-test/base.tcl >/dev/null
          awk '/^        place \{/ { copying = 1 } /^        route \{/ { copying = 0 } copying { print }' \
            generated-rqa-test/physical_stage.tcl > generated-rqa-test/place-case.tcl
          grep -F 'opt_design -directive $directive' generated-rqa-test/place-case.tcl >/dev/null
          grep -F 'if {[info exists cfg(peer_backend)] && $cfg(peer_backend) eq "aurora_qsfp1"} {' generated-rqa-test/physical_stage.tcl >/dev/null
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
          u280_elaboration_script=${phaseScript "u280-app-elaboration-command.sh" evalU280App.coyoteTwoStage.stages.elaboration.buildPhase}
          grep -F 'make project' "$u280_elaboration_script" >/dev/null
          grep -F 'coyote-app-elaboration.tcl' "$u280_elaboration_script" >/dev/null
          if grep -E '^[[:space:]]*make (synth|app|bitgen)[[:space:]]*$' "$u280_elaboration_script" >/dev/null; then
            echo 'U280 RTL elaboration unexpectedly invokes synthesis or implementation' >&2
            exit 1
          fi
          grep -F 'example-u280-app-elaboration-0.1.0' \
            ${phaseScript "u280-app-elaboration-gate-dependency.sh" evalU280App.coyoteTwoStage.stages.synth.buildPhase} >/dev/null
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
          for script in \
            ${phaseScript "u280-app-link-evidence-install.sh" evalU280App.coyoteTwoStage.stages.link.installPhase} \
            ${phaseScript "v80-app-link-evidence-install.sh" evalV80App.coyoteTwoStage.stages.link.installPhase}; do
            grep -F 'coyote.app-link-integrity/v1' "$script" >/dev/null
            grep -F 'coyote.app-link-partition-pins/v1' "$script" >/dev/null
            grep -F 'routedLockedCheckpointSha256' "$script" >/dev/null
            grep -F 'protectedStatic.placement.before == .protectedStatic.placement.after' "$script" >/dev/null
            grep -F 'protectedStatic.routing.before == .protectedStatic.routing.after' "$script" >/dev/null
            grep -F 'app_link_partition_pins_c0.json' "$script" >/dev/null
            grep -F 'app_link_integrity_c0.json' "$script" >/dev/null
          done
          grep -F '${builtins.unsafeDiscardStringContext (toString evalU280App.coyoteTwoStage.stages.link)}/reports/config_0/. "$build_dir/reports/config_0/"' \
            ${phaseScript "u280-app-final-link-evidence.sh" evalU280App.buildPhase} >/dev/null
          grep -F '${builtins.unsafeDiscardStringContext (toString evalV80App.coyoteTwoStage.stages.link)}/reports/config_0/. "$build_dir/reports/config_0/"' \
            ${phaseScript "v80-app-final-link-evidence.sh" evalV80App.buildPhase} >/dev/null
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
