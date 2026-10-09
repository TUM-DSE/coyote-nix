#!/usr/bin/env python3
"""Validate immutable V80 shell region outputs and bind their artifact identities."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def exported(root, name):
    values = re.findall(
        r"^\s*set\(\s*" + name + r'\s+"?([0-9]+)"?\s*\)\s*$',
        (root / "export.cmake").read_text(), re.MULTILINE,
    )
    if name == "N_CONFIG" and not values:
        regions = exported(root, "N_REGIONS")
        if regions == 1:
            return 1  # Compatibility with pre-topology single-region exports.
    if len(values) != 1:
        raise ValueError(f"expected one numeric {name} in export.cmake")
    return int(values[0])


def region_entries(count):
    if not 1 <= count <= 15:
        raise ValueError("region count must be 1..15")
    return [{
        "region": index,
        "cell": f"inst_shell/inst_dynamic/inst_user_wrapper_{index}",
        "seedCheckpoint": f"checkpoints/config_0/user_synthed_c0_{index}.dcp",
    } for index in range(count)]


def check_export(root, count):
    if exported(root, "N_CONFIG") != 1 or exported(root, "N_REGIONS") != count:
        raise ValueError("exported configuration/region topology differs from package contract")


def shell_inventory(root, count, metadata_path, output_path):
    check_export(root, count)
    metadata = json.loads(metadata_path.read_text())
    extension = "pdi" if metadata["fpgaArchitecture"] == "versal" else "bin"
    if metadata["fpgaArchitecture"] not in ("versal", "ultrascale_plus"):
        raise ValueError("unsupported shell architecture")
    entries = region_entries(count)
    for entry in entries:
        checkpoint = root / entry["seedCheckpoint"]
        image_path = f"bitstreams/config_0/vfpga_c0_{entry['region']}.{extension}"
        image = root / image_path
        entry["seedCheckpointSha256"] = digest(checkpoint)
        entry["seedImage"] = image_path
        entry["seedImageSha256"] = digest(image)
    metadata["topology"] = {"configurations": 1, "regions": count}
    metadata["physicalRegions"] = entries
    output_path.write_text(json.dumps(metadata, sort_keys=True, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check-export")
    check.add_argument("root", type=Path)
    check.add_argument("regions", type=int)
    inventory = sub.add_parser("shell-inventory")
    inventory.add_argument("root", type=Path)
    inventory.add_argument("regions", type=int)
    inventory.add_argument("metadata", type=Path)
    inventory.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.command == "check-export":
        check_export(args.root, args.regions)
    else:
        shell_inventory(args.root, args.regions, args.metadata, args.output)


if __name__ == "__main__":
    main()
