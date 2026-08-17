#!/usr/bin/env python3
"""Render or validate the single accepted Versal R5 deployment composition."""

import argparse
import re
from pathlib import Path, PurePosixPath


def safe_relative(value):
    path = PurePosixPath(value)
    raw_parts = value.split("/")
    if (
        path.is_absolute()
        or value in ("", ".")
        or any(part in ("", ".", "..") for part in raw_parts)
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", value) is None
    ):
        raise ValueError(f"unsafe relative path: {value}")
    return value


def render(base_pdi, firmware_elf, subsystem_id):
    safe_relative(base_pdi)
    safe_relative(firmware_elf)
    if subsystem_id != "0x1c000000":
        raise ValueError("subsystem ID must be the R5 TCM-owning subsystem 0x1c000000")
    return f"""all:
{{
    image
    {{
        {{ type=bootimage, file={base_pdi} }}
    }}
    image
    {{
        id = {subsystem_id}, name=rpu_subsystem, delay_handoff
        {{ core=r5-0, file={firmware_elf} }}
    }}
}}
"""


def normalized(text):
    return " ".join(text.split())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", type=Path)
    parser.add_argument("--base-pdi", default="platform-base.pdi")
    parser.add_argument("--firmware-elf", default="firmware.elf")
    parser.add_argument("--subsystem-id", default="0x1c000000")
    args = parser.parse_args()
    if (args.output is None) == (args.check is None):
        parser.error("specify exactly one of --output or --check")
    try:
        expected = render(args.base_pdi, args.firmware_elf, args.subsystem_id)
    except ValueError as error:
        raise SystemExit(f"R5 BIF contract error: {error}") from error
    if args.output:
        args.output.write_text(expected)
        return
    actual = args.check.read_text()
    if normalized(actual) != normalized(expected):
        raise SystemExit("R5 BIF contract error: composition is not the exact one-base/one-R5 delayed-handoff policy")


if __name__ == "__main__":
    main()
