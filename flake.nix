{
  description = "Reusable Nix tooling for Coyote FPGA development";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    let
      coyoteNixLib = import ./lib;
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
          xilinxVersion = "site-selected-u280-build-version";
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
        };
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
          (phaseScript "u280-app-build-phase.sh" evalU280App.buildPhase)
          (phaseScript "u280-app-install-phase.sh" evalU280App.installPhase)
          (phaseScript "v80-shell-build-phase.sh" evalV80Shell.buildPhase)
          (phaseScript "v80-shell-install-phase.sh" evalV80Shell.installPhase)
          (phaseScript "v80-app-build-phase.sh" evalV80App.buildPhase)
          (phaseScript "v80-app-install-phase.sh" evalV80App.installPhase)
        ];
      in
      {
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

        checks.two-stage-packages-eval =
          assert coyoteNixLib ? mkCoyoteShellPackage;
          assert coyoteNixLib ? mkCoyoteSourceChecks;
          assert coyoteNixLib ? mkCoyoteAppPackage;
          assert evalU280Shell.coyoteTwoStage.kind == "shell";
          assert
            evalU280Shell.coyoteTwoStage.stageNames == [
              "synth"
              "routed"
              "dynamic"
              "bitgen"
            ];
          assert evalU280Shell.coyoteTwoStage.stages ? routed;
          assert evalU280Shell.coyoteTwoStage.enShellPblock;
          assert evalV80Shell.coyoteTwoStage.kind == "shell";
          assert
            evalV80Shell.coyoteTwoStage.stageNames == [
              "synth"
              "dynamic"
              "bitgen"
            ];
          assert !(evalV80Shell.coyoteTwoStage.stages ? routed);
          assert !evalV80Shell.coyoteTwoStage.enShellPblock;
          assert evalU280App.coyoteTwoStage.kind == "app";
          assert evalU280App.coyoteTwoStage.shellPath == toString evalU280Shell;
          assert builtins.elem "-DBUILD_APP:STRING=1" evalU280App.coyoteTwoStage.appCmakeFlags;
          assert builtins.elem "-DSHELL_PATH=${evalU280Shell}" evalU280App.coyoteTwoStage.appCmakeFlags;
          assert evalV80App.coyoteTwoStage.kind == "app";
          assert evalV80App.coyoteTwoStage.shellPath == toString evalV80Shell;
          assert builtins.elem "-DEN_SHELL_PBLOCK:STRING=0" evalV80App.coyoteTwoStage.appCmakeFlags;
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
