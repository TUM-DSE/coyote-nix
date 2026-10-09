"""Exercise complete immutable V80 shell region export inventories."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

TOOL = Path(sys.argv[1]).resolve()


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def invoke(command, root, count, *args, ok=True):
    result = subprocess.run([sys.executable, str(TOOL), command, str(root), str(count), *map(str, args)],
                            text=True, capture_output=True)
    assert (result.returncode == 0) == ok, result.stderr
    return result


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    (root / "export.cmake").write_text('set(N_CONFIG "1")\nset(N_REGIONS "3")\n')
    base = {"schemaVersion": 1, "kind": "coyote-shell", "board": "v80",
            "fpgaArchitecture": "versal", "artifacts": []}
    metadata = root / "base.json"
    output = root / "shell.json"
    metadata.write_text(json.dumps(base))
    for index in range(3):
        write(root / f"checkpoints/config_0/user_synthed_c0_{index}.dcp", f"seed-{index}".encode())
        write(root / f"bitstreams/config_0/vfpga_c0_{index}.pdi", f"image-{index}".encode())
    invoke("shell-inventory", root, 3, metadata, output)
    shell = json.loads(output.read_text())
    assert shell["topology"] == {"configurations": 1, "regions": 3}
    assert [entry["region"] for entry in shell["physicalRegions"]] == [0, 1, 2]
    for entry in shell["physicalRegions"]:
        assert entry["seedCheckpointSha256"] == hashlib.sha256((root / entry["seedCheckpoint"]).read_bytes()).hexdigest()
        assert entry["seedImageSha256"] == hashlib.sha256((root / entry["seedImage"]).read_bytes()).hexdigest()
    invoke("check-export", root, 3)
    invoke("check-export", root, 2, ok=False)
    (root / "bitstreams/config_0/vfpga_c0_2.pdi").unlink()
    invoke("shell-inventory", root, 3, metadata, output, ok=False)
    (root / "export.cmake").write_text('set(N_REGIONS "1")\n')
    invoke("check-export", root, 1)
    print("PASS: complete per-region checkpoint/image hashes and legacy one-region export")
