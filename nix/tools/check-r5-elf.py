#!/usr/bin/env python3
"""Validate that a freestanding Cortex-R5 ELF is wholly bounded by declared TCM."""

import argparse
import hashlib
import json
import re
from pathlib import Path

from elftools.elf.elffile import ELFFile


class ContractError(RuntimeError):
    pass


def number(value):
    return int(value, 0) if isinstance(value, str) else int(value)


def interval_in_region(start, size, region):
    if size < 0 or start < 0:
        return False
    end = start + size
    region_start = number(region["base"])
    region_end = region_start + number(region["bytes"])
    return end >= start and start >= region_start and end <= region_end


def in_tcm(start, size, contract):
    return any(interval_in_region(start, size, contract[name]) for name in ("atcm", "btcm"))


def require(condition, message):
    if not condition:
        raise ContractError(message)


def validate_contract(contract):
    required_fields = {
        "api", "processor", "core", "xilinxVersion", "hardwareContractSha256",
        "entry", "atcm", "btcm", "scratch", "bootState", "vectorsBytes",
        "statusAddress", "statusBytes", "requiredSymbols", "absoluteSymbols",
        "platformContractId",
    }
    require(set(contract) == required_fields, "platform contract fields do not match v1")
    require(contract["api"] == "coyote.v80-r5-platform/v1", "wrong platform contract API")
    require(contract["processor"] == "psv_cortexr5_0", "wrong processor")
    require(contract["core"] == "r5-0", "wrong boot core")
    require(isinstance(contract["xilinxVersion"], str) and contract["xilinxVersion"], "missing Xilinx version")
    require(re.fullmatch(r"[0-9a-f]{64}", contract["hardwareContractSha256"]) is not None,
            "hardware contract hash is malformed")

    contract_id = contract["platformContractId"]
    unhashed = dict(contract)
    del unhashed["platformContractId"]
    canonical = json.dumps(unhashed, sort_keys=True, separators=(",", ":")).encode()
    require(contract_id == hashlib.sha256(canonical).hexdigest(), "platform contract ID mismatch")

    for name in ("atcm", "btcm", "scratch"):
        require(set(contract[name]) == {"base", "bytes"}, f"{name} range fields are invalid")
        require(number(contract[name]["base"]) >= 0, f"{name} base is invalid")
        require(number(contract[name]["bytes"]) > 0, f"{name} size must be positive")
    ranges = [contract[name] for name in ("atcm", "btcm", "scratch")]
    for index, region in enumerate(ranges):
        start = number(region["base"])
        end = start + number(region["bytes"])
        for other in ranges[index + 1 :]:
            other_start = number(other["base"])
            other_end = other_start + number(other["bytes"])
            require(end <= other_start or other_end <= start, "platform ranges overlap")

    entry = number(contract["entry"])
    vectors_bytes = number(contract["vectorsBytes"])
    status_address = number(contract["statusAddress"])
    status_bytes = number(contract["statusBytes"])
    require(vectors_bytes == 32 and interval_in_region(entry, vectors_bytes, contract["atcm"]),
            "vector contract is outside ATCM")
    require(status_bytes == 64 and status_address % 64 == 0 and
            interval_in_region(status_address, status_bytes, contract["btcm"]),
            "status contract is outside/aligned incorrectly for BTCM")

    expected_boot_state = {
        "coldResetRequired": True,
        "armExceptions": True,
        "littleEndian": True,
        "cachesDisabled": True,
        "delayedHandoff": True,
        "warmRehandoffSupported": False,
        "tcmEcc": "platform-managed-unverified",
    }
    require(contract["bootState"] == expected_boot_state, "unsupported R5 boot-state contract")
    require(set(contract["requiredSymbols"]) == {"_start", "r5_main", "r5_exception_trap", "r5_internal_trap"},
            "required symbol contract is invalid")

    stack_names = ["__stack_floor", "__svc_stack_top", "__abt_stack_top",
                   "__und_stack_top", "__irq_stack_top", "__fiq_stack_top"]
    require(set(contract["absoluteSymbols"]) == set(stack_names), "stack symbol contract is invalid")
    stack_values = [number(contract["absoluteSymbols"][name]) for name in stack_names]
    require(stack_values == sorted(stack_values) and len(set(stack_values)) == len(stack_values),
            "stack symbols are not strictly ordered")
    require(all(value % 8 == 0 for value in stack_values), "stack symbols are not aligned")
    require(status_address + status_bytes <= stack_values[0], "status overlaps stack reservation")
    btcm_end = number(contract["btcm"]["base"]) + number(contract["btcm"]["bytes"])
    require(stack_values[-1] == btcm_end, "FIQ stack top must equal BTCM end")
    require(all(number(contract["btcm"]["base"]) <= value <= btcm_end for value in stack_values),
            "stack symbols are outside BTCM")


def validate(path, contract):
    validate_contract(contract)
    file_bytes = path.stat().st_size
    with path.open("rb") as stream:
        elf = ELFFile(stream)
        require(elf.elfclass == 32, "ELF must be 32-bit")
        require(elf.little_endian, "ELF must be little-endian")
        require(elf.header["e_machine"] == "EM_ARM", "ELF machine must be ARM")
        require(elf.header["e_type"] == "ET_EXEC", "ELF must be executable")

        entry = int(elf.header["e_entry"])
        expected_entry = number(contract["entry"])
        require(entry == expected_entry, f"entry must be 0x{expected_entry:08x}")
        require(in_tcm(entry, 1, contract), "entry is outside TCM")

        flags = int(elf.header["e_flags"])
        require((flags & 0x400) == 0, "hard-float parameter ABI is forbidden")

        load_segments = []
        for segment in elf.iter_segments():
            kind = segment.header["p_type"]
            require(kind not in ("PT_INTERP", "PT_DYNAMIC", "PT_TLS"), f"forbidden segment {kind}")
            if kind != "PT_LOAD":
                continue
            mem_size = int(segment.header["p_memsz"])
            file_size = int(segment.header["p_filesz"])
            require(file_size <= mem_size, "load segment file size exceeds memory size")
            segment_offset = int(segment.header["p_offset"])
            require(segment_offset + file_size <= file_bytes, "load segment extends past end of ELF")
            if mem_size == 0:
                continue
            physical = int(segment.header["p_paddr"])
            virtual = int(segment.header["p_vaddr"])
            require(physical == virtual, "load segment physical and virtual addresses must match")
            require(in_tcm(physical, mem_size, contract), f"load segment 0x{physical:x}+0x{mem_size:x} is outside TCM")
            load_segments.append(
                (physical, mem_size, int(segment.header["p_flags"]),
                 segment_offset, file_size)
            )
        require(load_segments, "ELF has no loadable segment")
        for index, (start, size, _, _, _) in enumerate(load_segments):
            for other_start, other_size, _, _, _ in load_segments[index + 1 :]:
                require(start + size <= other_start or other_start + other_size <= start, "load segments overlap")
        require(
            any(start <= entry < start + size and flags & 0x1
                for start, size, flags, _, _ in load_segments),
            "entry is not in an executable load segment",
        )

        stack_floor = number(contract["absoluteSymbols"]["__stack_floor"])
        allocated_sections = []
        for section in elf.iter_sections():
            name = section.name
            flags = int(section.header["sh_flags"])
            size = int(section.header["sh_size"])
            section_type = section.header["sh_type"]
            if section_type in ("SHT_REL", "SHT_RELA") and size:
                raise ContractError(f"relocation section {name} is forbidden")
            if flags & 0x2 and size:  # SHF_ALLOC
                start = int(section.header["sh_addr"])
                require(in_tcm(start, size, contract), f"allocated section {name} is outside TCM")
                compatible_segments = [
                    segment
                    for segment in load_segments
                    if segment[0] <= start and start + size <= segment[0] + segment[1]
                    and ((flags & 0x4) == 0 or segment[2] & 0x1)
                    and ((flags & 0x1) == 0 or segment[2] & 0x2)
                ]
                require(compatible_segments, f"allocated section {name} has no permission-compatible load segment")
                if section_type != "SHT_NOBITS":
                    section_offset = int(section.header["sh_offset"])
                    require(section_offset + size <= file_bytes, f"section {name} extends past end of ELF")
                    require(
                        any(
                            start + size <= segment_start + file_size
                            and segment_offset <= section_offset
                            and section_offset + size <= segment_offset + file_size
                            and section_offset - segment_offset == start - segment_start
                            for segment_start, _, _, segment_offset, file_size in compatible_segments
                        ),
                        f"allocated section {name} is not file-backed by its load segment",
                    )
                if interval_in_region(start, size, contract["btcm"]):
                    require(start + size <= stack_floor, f"allocated section {name} overlaps reserved stacks")
                if flags & 0x1:  # SHF_WRITE
                    require(section_type == "SHT_NOBITS", f"initialized writable section {name} is forbidden")
                allocated_sections.append((start, size, name))

        allocated_sections.sort()
        for (start, size, name), (next_start, _, next_name) in zip(
            allocated_sections, allocated_sections[1:]
        ):
            require(start + size <= next_start, f"allocated sections {name} and {next_name} overlap")

        vectors = elf.get_section_by_name(".vectors")
        require(vectors is not None, ".vectors is missing")
        require(vectors.header["sh_type"] == "SHT_PROGBITS", ".vectors must contain loadable bytes")
        require(int(vectors.header["sh_addr"]) == number(contract["entry"]), ".vectors must start at entry")
        require(int(vectors.header["sh_size"]) == number(contract["vectorsBytes"]), ".vectors has wrong size")
        vector_flags = int(vectors.header["sh_flags"])
        require(vector_flags & 0x2 and vector_flags & 0x4, ".vectors must be allocated and executable")
        require((vector_flags & 0x1) == 0, ".vectors must not be writable")

        status = elf.get_section_by_name(".fixture_status")
        require(status is not None, ".fixture_status is missing")
        require(int(status.header["sh_addr"]) == number(contract["statusAddress"]), ".fixture_status has wrong address")
        require(int(status.header["sh_size"]) == number(contract["statusBytes"]), ".fixture_status has wrong size")
        require(status.header["sh_type"] == "SHT_NOBITS", ".fixture_status must be NOLOAD/NOBITS")
        status_flags = int(status.header["sh_flags"])
        require(status_flags & 0x2 and status_flags & 0x1, ".fixture_status must be allocated and writable")
        require((status_flags & 0x4) == 0, ".fixture_status must not be executable")
        require(int(status.header["sh_addralign"]) >= 64, ".fixture_status must be 64-byte aligned")
        status_start = int(status.header["sh_addr"])
        status_size = int(status.header["sh_size"])
        require(
            any(start <= status_start and status_start + status_size <= start + size and flags & 0x2
                for start, size, flags, _, _ in load_segments),
            ".fixture_status is not mapped by a writable load segment",
        )

        symbol_table = elf.get_section_by_name(".symtab")
        require(symbol_table is not None, "symbol table is required")
        symbols = {symbol.name: symbol for symbol in symbol_table.iter_symbols()}
        for symbol in symbols.values():
            if symbol.entry["st_shndx"] == "SHN_UNDEF" and symbol.name:
                require(symbol.entry["st_info"]["bind"] == "STB_WEAK", f"unresolved symbol {symbol.name}")
        for required in contract["requiredSymbols"]:
            require(required in symbols, f"required symbol {required} is missing")
            symbol = symbols[required]
            require(symbol.entry["st_shndx"] != "SHN_UNDEF", f"required symbol {required} is undefined")
            require(symbol.entry["st_info"]["type"] == "STT_FUNC", f"required symbol {required} is not a function")
            symbol_value = int(symbol.entry["st_value"])
            require(int(symbol.entry["st_size"]) > 0, f"required symbol {required} has zero size")
            require(
                any(start <= symbol_value < start + size and flags & 0x1
                    for start, size, flags, _, _ in load_segments),
                f"required symbol {required} is outside executable load segments",
            )
        require(int(symbols["_start"].entry["st_value"]) == entry, "_start must equal ELF entry")
        for name, value in contract["absoluteSymbols"].items():
            require(name in symbols, f"required symbol {name} is missing")
            require(int(symbols[name].entry["st_value"]) == number(value), f"symbol {name} has wrong value")

        return {
            "api": "coyote-nix.r5-elf-report/v1",
            "elf": str(path),
            "entry": entry,
            "machine": "arm",
            "classBits": 32,
            "littleEndian": True,
            "loadSegments": len(load_segments),
            "tcmOnly": True,
            "hardFloatAbi": False,
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--elf", required=True, type=Path)
    parser.add_argument("--contract", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    contract = json.loads(args.contract.read_text())
    try:
        report = validate(args.elf, contract)
    except (ContractError, KeyError, ValueError) as error:
        raise SystemExit(f"R5 ELF contract error: {error}") from error
    encoded = json.dumps(report, sort_keys=True, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded)
    else:
        print(encoded, end="")


if __name__ == "__main__":
    main()
