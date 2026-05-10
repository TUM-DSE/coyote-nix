{
  description = "Reusable Nix tooling for Coyote FPGA development";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    let
      coyoteNixLib = import ./lib;
      linuxSystems = builtins.filter (system: builtins.match ".*-linux" system != null) flake-utils.lib.defaultSystems;
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        checks.shellcheck = pkgs.runCommand "shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          cd ${./.}
          shellcheck -s bash nix/tools/*.sh
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
    ) // {
      lib = coyoteNixLib;
    };
}
