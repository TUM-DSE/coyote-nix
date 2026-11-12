# A failed validation fails only a strict build. Otherwise the result is
# recorded and the build continues.
{ pkgs }:
let
  helpers = import ../lib/coyoteHwStageHelpers.nix {
    inherit pkgs;
    tools = { };
    coyoteRoot = ../.;
    hwSource = ../.;
    xilinxShareRoot = "/share/xilinx";
  };
  mkValidateStage =
    outcome: reasons:
    pkgs.runCommand "fixture-validate-${outcome}" { } ''
      mkdir -p "$out/checkpoints/config_0" "$out/reports/config_0"
      echo checkpoint > "$out/checkpoints/config_0/shell_routed_c0.dcp"
      echo '${
        builtins.toJSON {
          schemaVersion = 1;
          inherit outcome reasons;
        }
      }' > "$out/reports/config_0/validation.json"
    '';
  accepted = mkValidateStage "accepted" [ ];
  rejected = mkValidateStage "rejected" [ "setup WNS -0.125 ns" ];
  # The build script of a validation result, run below so a failure can be
  # observed instead of failing this check.
  script =
    stage: strict:
    pkgs.writeText "validation-result.sh"
      (helpers.mkValidationResult {
        pname = "validation-result";
        inherit stage strict;
        validationPath = "reports/config_0/validation.json";
      }).buildCommand;
  run =
    stage: strict:
    ''out="$TMPDIR/${stage.name}-${lib.boolToString strict}" bash -eu ${script stage strict}'';
  inherit (pkgs) lib;
in
pkgs.runCommand "implementation-gate-policy" { nativeBuildInputs = [ pkgs.jq ]; } ''
  ${run accepted false}
  ${run accepted true}
  test "$(cat "$TMPDIR/${accepted.name}-true/metadata/outcome")" = accepted

  ${run rejected false} 2> nonstrict.log
  grep -q 'WARNING: implementation validation rejected' nonstrict.log
  grep -q 'setup WNS -0.125 ns' nonstrict.log
  jq -e '.outcome == "rejected" and .strict == false' \
    "$TMPDIR/${rejected.name}-false/metadata/validation.json"
  test -e "$TMPDIR/${rejected.name}-false/checkpoints/config_0/shell_routed_c0.dcp"

  if ${run rejected true} 2> strict.log; then
    echo 'a strict build accepted a rejected validation' >&2
    exit 1
  fi
  grep -q 'ERROR: implementation validation rejected' strict.log

  touch "$out"
''
