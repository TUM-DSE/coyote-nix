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
      in
      {
        checks.shellcheck = pkgs.runCommand "shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          cd ${./.}
          shellcheck -s bash nix/tools/*.sh
          touch $out
        '';

        checks.board-packages-eval =
          assert evalBoardPackages ? "example-u280";
          assert evalBoardPackages ? "example-u280-static";
          assert evalBoardPackages ? "example-u280-sim";
          assert evalBoardPackages ? "example-v80";
          pkgs.runCommand "board-packages-eval" { } ''
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
