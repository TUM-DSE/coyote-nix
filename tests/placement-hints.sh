#!/usr/bin/env bash
set -euo pipefail

python=${1:?python interpreter required}
tclsh=${2:?Tcl interpreter required}
root=${3:?repository root required}
coyote_root=${4:?exact Coyote source required}
tool="$root/nix/tools/coyote-placement-hints.py"
tcl_tool="$root/nix/tools/coyote-placement-hints.tcl"
link_template="$coyote_root/scripts/dyn/flow_dyn_link_versal.tcl.in"
# Match literal Tcl variable references.
# shellcheck disable=SC2016
grep -F 'set static_dcp "$cfg(static_path)/static_synthed_$cfg(fdev)_gen$cfg(pcie_gen).dcp"' "$link_template" >/dev/null
# Match literal Tcl variable references.
# shellcheck disable=SC2016
grep -F 'set_property SCOPED_TO_CELLS {inst_static} [get_files $static_dcp]' "$link_template" >/dev/null
work=$(mktemp -d "${TMPDIR:-/tmp}/coyote-placement-hints.XXXXXX")
trap 'rm -rf "$work"' EXIT

cat > "$work/hints.json" <<'EOF'
{"api":"coyote-nix.placement-hints/v1","groups":[{"name":"queue0","cells":["inst_shell/qshell/output_queues[0].inst_output_queue"],"sites":["SLICE_X10Y20"]}]}
EOF
"$python" - "$coyote_root/scripts/impl/physical_stage.tcl.in" "$work/runner.tcl" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
for source, target in (('set phase "${IMPLEMENTATION_PHASE}"', 'set phase "place"'),
                       ('set place_directive "${IMPLEMENTATION_PLACE_DIRECTIVE}"', 'set place_directive "project"')):
    if text.count(source) != 1:
        raise SystemExit(f"Coyote template anchor changed: {source}")
    text = text.replace(source, target, 1)
Path(sys.argv[2]).write_text(text)
PY
"$python" "$tool" inject \
  --runner "$work/runner.tcl" \
  --manifest "$work/hints.json" \
  --apply-tcl "$tcl_tool" \
  --data-output "$work/data.tcl"
grep -F 'inst_static' "$tcl_tool" >/dev/null
grep -F 'coyote_apply_placement_hints' "$work/runner.tcl" >/dev/null

# The generated names remain single literal Tcl list elements; metacharacters cannot execute.
cat > "$work/literal.json" <<'EOF'
{"api":"coyote-nix.placement-hints/v1","groups":[{"name":"literal","cells":["inst_shell/x;$puts_HACK[0]"],"sites":["SLICE_X11Y21"]}]}
EOF
"$python" - "$tool" "$work/literal.json" "$work/literal.tcl" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("placement_hints", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
open(sys.argv[3], "w").write(module.emit_data(module.load_manifest(sys.argv[2])))
PY
"$tclsh" <<EOF > "$work/literal.out"
source {$work/literal.tcl}
puts [lindex [lindex [lindex \$::coyote_placement_hint_groups 0] 1] 0]
EOF
# Injection-test data must remain literal.
# shellcheck disable=SC2016
grep -Fx 'inst_shell/x;$puts_HACK[0]' "$work/literal.out"

# Mock only Vivado collection/property commands. No Vivado process or device is used.
"$tclsh" "$root/tests/placement-hints-mock.tcl" "$tcl_tool"

# Empty, intersecting, unsafe schema and malformed runner anchors fail closed.
"$python" - "$tool" "$work" <<'PY'
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location("placement_hints", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
w = pathlib.Path(sys.argv[2])
valid = {"api":"coyote-nix.placement-hints/v1","groups":[{"name":"a","cells":["x/y"],"sites":["SLICE_X1Y1"]}]}
for mutate in (
    lambda x: x.update(groups=[]),
    lambda x: x["groups"].append({"name":"b","cells":["x/y/child"],"sites":["SLICE_X2Y2"]}),
    lambda x: x["groups"][0].update(cells=["bad\nselector"]),
):
    candidate = json.loads(json.dumps(valid)); mutate(candidate)
    p = w / "invalid.json"; p.write_text(json.dumps(candidate))
    try: m.load_manifest(p)
    except SystemExit: pass
    else: raise SystemExit("invalid hint manifest unexpectedly accepted")
runner = w / "bad-runner.tcl"
runner.write_text('open_checkpoint $input_dcp\n')
args = type("Args", (), {"manifest": str(w / "hints.json"), "runner": str(runner), "apply_tcl":str(pathlib.Path(sys.argv[1]).with_name("coyote-placement-hints.tcl")), "data_output":str(w / "bad-data.tcl")})()
try: m.inject(args)
except SystemExit: pass
else: raise SystemExit("runner without exact anchors unexpectedly accepted")
PY

echo "placement hint schema, Tcl admission behavior, and fail-closed wrapper tests passed"
