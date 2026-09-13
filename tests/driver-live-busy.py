#!/usr/bin/env python3
"""Explicit live test: an open reconfiguration device must prevent driver removal.

Run only after exclusive board ownership and kernel-health checks, using the
flake-provided Python and candidate unload-driver. Never run against a helper
that unbinds devices before rmmod. This test does not reset or program hardware.
"""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bdf", required=True)
parser.add_argument("--device", type=Path, required=True)
parser.add_argument("--unload-tool", type=Path, required=True)
parser.add_argument("--confirm-hardware-test", action="store_true", required=True)
args = parser.parse_args()
if not re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{2}:[01][0-9a-f]\.[0-7]", args.bdf):
    parser.error("use a canonical PCI BDF")
endpoint = Path("/sys/bus/pci/devices") / args.bdf
binding = endpoint / "driver"
owner = binding.resolve(strict=True).name
prefixes = {
    "coyote_driver": "coyote_fpga",
    "coyote_driver_ultrascale_plus": "coyote_ultrascale_plus_fpga",
    "coyote_driver_versal": "coyote_versal_fpga",
}
if owner not in prefixes or not re.fullmatch(prefixes[owner] + r"_[0-9]+_reconfig", args.device.name):
    parser.error("device namespace must match the selected Coyote owner")
if not stat.S_ISCHR(args.device.stat().st_mode):
    parser.error("expected a character device")
refcount = Path("/sys/module") / owner / "refcnt"
before_refs = int(refcount.read_text())
if before_refs != 0:
    parser.error("driver already has references; establish exclusive ownership first")
before = (binding.resolve(strict=True), endpoint.stat().st_ino, (endpoint / "resource").read_bytes())
fd = os.open(args.device, os.O_RDWR | os.O_CLOEXEC)
try:
    if int(refcount.read_text()) <= before_refs:
        raise RuntimeError("opened device did not pin selected module; refusing removal test")
    result = subprocess.run(
        [str(args.unload_tool.resolve(strict=True))],
        env={**os.environ, "FPGA_BDF": args.bdf, "LC_ALL": "C"},
        capture_output=True, text=True, timeout=10,
    )
    after = (binding.resolve(strict=True), endpoint.stat().st_ino, (endpoint / "resource").read_bytes())
    if result.returncode == 0 or "is in use" not in result.stderr or after != before:
        raise RuntimeError(f"busy removal invariant failed: {result.returncode}, {result.stderr!r}")
    print(json.dumps({"bdf": args.bdf, "module": owner, "device": str(args.device),
                      "exitCode": result.returncode, "stderr": result.stderr,
                      "bindingAndResourcesUnchanged": True}))
finally:
    os.close(fd)
