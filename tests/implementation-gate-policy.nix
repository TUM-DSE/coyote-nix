{ pkgs }:
let
  helpers = import ../lib/coyoteHwStageHelpers.nix {
    inherit pkgs;
    tools = { };
    coyoteRoot = ../.;
    hwSource = ../.;
    xilinxShareRoot = "/share/xilinx";
  };
  context = {
    board = "v80";
    architecture = "versal";
    part = "xcv80-fixture";
    flow = "build-app";
    sourceId = "source-fixture";
    coyoteSourceId = "coyote-fixture";
    constraintsId = "constraints-fixture";
    toolId = "tool-fixture";
    toolVersion = "2025.1";
  };
  contextId = builtins.hashString "sha256" (builtins.toJSON context);
  contextFile = pkgs.writeText "gate-context.json" (builtins.toJSON (context // { id = contextId; }));
  command = enforce: (helpers.mkImplementationStageGate {
    pname = "implementation-policy-gate";
    stage = "$stage";
    expectedContext = contextId;
    enforceStrictSignoff = enforce;
  }).buildCommand;
  strict = pkgs.writeText "strict-gate.sh" (command true);
  nonstrict = pkgs.writeText "nonstrict-gate.sh" (command false);
in
pkgs.runCommand "implementation-gate-policy" { nativeBuildInputs = [ pkgs.python3 pkgs.jq ]; } ''
  result="$out"
  work="$TMPDIR/stages"
  mkdir -p "$work"
  export work
  python3 - ${contextFile} ${../nix/tools/coyote-implementation-stage.py} <<'PY'
import json, os, pathlib, subprocess, sys
context = json.load(open(sys.argv[1]))
previous = None
for phase in ["inputs", "link", "place", "route", "validate"]:
    root = pathlib.Path(os.environ["work"]) / phase
    root.mkdir()
    (root / "checkpoint.dcp").write_text(phase)
    spec = {"phase": phase, "unit": "config_0", "context": context,
            "artifacts": [{"role": "validated-checkpoint" if phase == "validate" else phase + "-checkpoint", "path": "checkpoint.dcp"}]}
    if previous:
        spec["predecessorPath"] = str(previous)
    if phase == "validate":
        (root / "validation.json").write_text(json.dumps({"outcome": "accepted", "reasons": []}))
        spec["outcomePath"] = "validation.json"
        spec["artifacts"].append({"role": "validation-result", "path": "validation.json"})
    specfile = root / "spec.json"
    specfile.write_text(json.dumps(spec))
    subprocess.run([sys.executable, sys.argv[2], "write", str(specfile), str(root), str(root)], check=True)
    previous = root
PY
  export stage="$work/validate"
  if out="$TMPDIR/strict" bash -eu ${strict} > strict.log 2>&1; then
    echo 'strict gate accepted missing classification' >&2; exit 1
  fi
  cat strict.log
  grep -q 'strict physical signoff rejected validation evidence' strict.log
  out="$TMPDIR/nonstrict" bash -eu ${nonstrict}
  jq -e '.enforceStrictSignoff == false' "$TMPDIR/nonstrict/metadata/validation-policy.json"
  test ! -e "$TMPDIR/nonstrict/metadata/strict-signoff.json"
  printf '{"outcome":"rejected","reasons":["routing error"]}\n' > "$stage/validation.json"
  python3 ${../nix/tools/coyote-implementation-stage.py} write "$stage/spec.json" "$stage" "$stage"
  if out="$TMPDIR/rejected" bash -eu ${nonstrict}; then
    echo 'non-strict gate accepted rejected validation' >&2; exit 1
  fi
  printf 'tampered' >> "$stage/checkpoint.dcp"
  if out="$TMPDIR/tampered" bash -eu ${nonstrict}; then
    echo 'non-strict gate accepted corrupted stage' >&2; exit 1
  fi
  mkdir -p "$result"
  cp strict.log "$result/"
  echo PASS > "$result/result"
''
