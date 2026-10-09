"""Exercise generated shell imports against real CMake multi-output Make rules."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

cases = json.loads(Path(sys.argv[1]).read_text())
tool = str(Path(sys.argv[2]).resolve())


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    context = dict(board="v80", architecture="versal", part="xcv80", flow="shell",
                   sourceId="fixture", constraintsId="fixture", toolId="fixture", toolVersion="2025.1")
    context["id"] = hashlib.sha256(json.dumps(context, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    for case in cases:
        count = case["count"]
        stage = root / f"inputs-{count}"
        paths = ["checkpoints/shell/shell_synthed.dcp"] + [
            f"checkpoints/config_0/user_synthed_c0_{i}.dcp" for i in range(count)]
        roles = ["shell-synthesized-checkpoint", "seed-synthesized-checkpoint"] + [
            f"seed-synthesized-checkpoint-region-{i}" for i in range(1, count)]
        for path in paths:
            target = stage / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(path)
            os.utime(target, (1, 1))  # immutable-store timestamps precede configuration
        spec = root / f"spec-{count}.json"
        spec.write_text(json.dumps(dict(phase="inputs", unit="config_0", context=context,
                                       artifacts=[dict(role=r, path=p) for r, p in zip(roles, paths)])))
        run(sys.executable, tool, "write", str(spec), str(stage), str(stage))
        for phase in case["phases"]:
            source = root / f"{count}-{phase['name']}"
            source.mkdir()
            build = source / "build"
            # Minimal producer contract: one synthesis invocation owns all seed outputs.
            outputs = " ".join(paths[1:])
            (source / "CMakeLists.txt").write_text(f'''cmake_minimum_required(VERSION 3.20)
project(imported_checkpoints NONE)
file(WRITE "${{CMAKE_BINARY_DIR}}/synth_user.tcl" "configured dependency")
add_custom_command(OUTPUT {outputs}
  COMMAND ${{CMAKE_COMMAND}} -E echo "UNEXPECTED_SYNTHESIS"
  COMMAND ${{CMAKE_COMMAND}} -E false
  DEPENDS "${{CMAKE_BINARY_DIR}}/synth_user.tcl" "${{CMAKE_BINARY_DIR}}/CMakeCache.txt" {paths[0]})
add_custom_target(dynamic_link
  COMMAND ${{CMAKE_COMMAND}} -E touch linked
  DEPENDS {outputs} {paths[0]})
''')
            run("cmake", "-S", str(source), "-B", str(build), "-G", "Unix Makefiles")
            script = phase["buildPhase"].split("<<'__COYOTE_NIX_PRE_BUILD_SETUP_EOF__'\n", 1)[1].split("__COYOTE_NIX_PRE_BUILD_SETUP_EOF__", 1)[0]
            # Redirect only immutable fixture location, context and interpreter/tool;
            # retain actual generated role selection and timestamp normalization.
            original_stage = re.search(r"validate (\S+)", script).group(1)
            script = script.replace(original_stage, str(stage))
            script = re.sub(r"--context \S+", "--context " + context["id"], script)
            script = re.sub(r"/nix/store/\S+/bin/python /nix/store/\S+-coyote-implementation-stage.py", f"{sys.executable} {tool}", script)
            env = dict(os.environ, build_dir=str(build))
            if count > 1:
                legacy = re.sub(r"seed-synthesized-checkpoint-region-\d+", "", script)
                run("bash", "-euc", legacy, env=env)
                assert (build / paths[1]).exists() and not (build / paths[-1]).exists()
                result = subprocess.run(["make", "-C", str(build), "dynamic_link"], text=True, capture_output=True)
                assert result.returncode and "UNEXPECTED_SYNTHESIS" in result.stdout
                print("PASS: legacy role selection reproduces unexpected synthesis")
            run("bash", "-euc", script, env=env)
            for path in paths:
                assert (build / path).read_bytes() == (stage / path).read_bytes(), path
                assert (build / path).stat().st_mtime_ns >= (build / "synth_user.tcl").stat().st_mtime_ns
            run("make", "-C", str(build), "dynamic_link")
            assert (build / "linked").exists()
            if count > 1:
                # Demonstrate actual CMake secondary-output invalidation, not a
                # source-string assertion: the formerly omitted last seed is fatal.
                (build / paths[-1]).unlink()
                result = subprocess.run(["make", "-C", str(build), "dynamic_link"], text=True, capture_output=True)
                assert result.returncode and "UNEXPECTED_SYNTHESIS" in result.stdout
            # Production validation must still reject corrupted immutable inputs.
            victim = stage / paths[-1]
            original = victim.read_bytes()
            victim.write_bytes(b"corrupted")
            result = subprocess.run(["bash", "-euc", script], env=env, capture_output=True)
            assert result.returncode, "corrupt predecessor accepted"
            victim.write_bytes(original)
            print(f"PASS regions={count} phase={phase['name']}: complete import, make reuse, integrity rejection")
