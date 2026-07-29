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
        checks.shellcheck = pkgs.runCommand "shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          cd ${./.}
          shellcheck -s bash nix/tools/*.sh tests/*.sh
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
