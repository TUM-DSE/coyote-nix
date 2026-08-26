#!/usr/bin/env python3
"""Apply narrowly scoped Vivado 2023.2 U280 generated-Tcl workarounds."""

from pathlib import Path
import sys


def replace_once(text: str, old: str, new: str, source: Path) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{source}: expected exactly one generated Tcl fragment ({count} found): {old}")
    return text.replace(old, new)


def patch_base(path: Path) -> None:
    text = path.read_text()
    replacements = [
        ('    set prefix "shell_"', '    set prefix "shell_${phase}"'),
        ('    if {$phase in {opt place}} {', '    if {0 && $phase in {opt place}} {'),
        ('"$report_dir/_utilization.rpt"', '"$report_dir/${prefix}_utilization${report_suffix}.rpt"'),
        ('"$report_dir/_timing_summary.rpt"', '"$report_dir/${prefix}_timing_summary${report_suffix}.rpt"'),
        ('"$report_dir/_qor_assessment.rpt"', '"$report_dir/${prefix}_qor_assessment${report_suffix}.rpt"'),
        ('"$report_dir/_route_status.rpt"', '"$report_dir/${prefix}_route_status${report_suffix}.rpt"'),
        ('"$report_dir/_congestion.rpt"', '"$report_dir/${prefix}_congestion${report_suffix}.rpt"'),
        ('"$report_dir/_complexity.rpt"', '"$report_dir/${prefix}_complexity${report_suffix}.rpt"'),
        ('"$report_dir/_logic_levels.rpt"', '"$report_dir/${prefix}_logic_levels${report_suffix}.rpt"'),
        ('"$report_dir/_high_fanout.rpt"', '"$report_dir/${prefix}_high_fanout${report_suffix}.rpt"'),
        ('"$report_dir/_diagnosis.json"', '"$report_dir/${prefix}_diagnosis${report_suffix}.json"'),
        (
            '    set unrouted ""',
            "\n".join(
                [
                    '    if {$phase in {opt place} && $rqa_report eq ""} {',
                    '      set rqa_report "$report_dir/${prefix}_qor_assessment${report_suffix}.rpt"',
                    '      set rqa_fd [open $rqa_report w]',
                    '      puts $rqa_fd "QoR Assessment unavailable: disabled for U280 under Vivado 2023.2 after a native tool crash"',
                    '      close $rqa_fd',
                    '    }',
                    '    set unrouted ""',
                ]
            ),
        ),
    ]
    for old, new in replacements:
        text = replace_once(text, old, new, path)
    path.write_text(text)


def patch_physical_stage(path: Path) -> None:
    text = path.read_text()
    checkpoint = '    write_checkpoint -force $output_dcp\n'
    text = replace_once(text, checkpoint, "", path)
    observation_boundary = '    if {$incremental_mode eq "reference" && $phase in {place route}} {'
    text = replace_once(
        text,
        observation_boundary,
        checkpoint + observation_boundary,
        path,
    )
    path.write_text(text)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: patch-u280-vivado-2023.2-physical-stage.py BASE_TCL PHYSICAL_STAGE_TCL")
    base = Path(sys.argv[1])
    physical = Path(sys.argv[2])
    patch_base(base)
    patch_physical_stage(physical)


if __name__ == "__main__":
    main()
