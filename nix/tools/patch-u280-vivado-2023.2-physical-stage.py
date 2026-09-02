#!/usr/bin/env python3
"""Apply narrowly scoped Vivado 2023.2 U280 generated-Tcl workarounds."""

from pathlib import Path
import re
import sys


def replace_once(text: str, old: str, new: str, source: Path) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{source}: expected exactly one generated Tcl fragment ({count} found): {old}")
    return text.replace(old, new)


def patch_base(path: Path) -> None:
    text = path.read_text()
    legacy_reports = [
        ('    set prefix "shell_"', '    set prefix "shell_${phase}"'),
        ('"$report_dir/_utilization.rpt"', '"$report_dir/${prefix}_utilization${report_suffix}.rpt"'),
        ('"$report_dir/_timing_summary.rpt"', '"$report_dir/${prefix}_timing_summary${report_suffix}.rpt"'),
        ('"$report_dir/_qor_assessment.rpt"', '"$report_dir/${prefix}_qor_assessment${report_suffix}.rpt"'),
        ('"$report_dir/_route_status.rpt"', '"$report_dir/${prefix}_route_status${report_suffix}.rpt"'),
        ('"$report_dir/_congestion.rpt"', '"$report_dir/${prefix}_congestion${report_suffix}.rpt"'),
        ('"$report_dir/_complexity.rpt"', '"$report_dir/${prefix}_complexity${report_suffix}.rpt"'),
        ('"$report_dir/_logic_levels.rpt"', '"$report_dir/${prefix}_logic_levels${report_suffix}.rpt"'),
        ('"$report_dir/_high_fanout.rpt"', '"$report_dir/${prefix}_high_fanout${report_suffix}.rpt"'),
        ('"$report_dir/_diagnosis.json"', '"$report_dir/${prefix}_diagnosis${report_suffix}.json"'),
    ]
    if legacy_reports[0][0] in text:
        for old, new in legacy_reports:
            text = replace_once(text, old, new, path)
    else:
        # Current Coyote already emits phase-qualified report names. Keep this
        # compatibility check strict so an unrelated template change fails closed.
        for fragment in (
            'set prefix [format "shell_%s" $phase]',
            'set timing_path [file join $report_dir [format "%s_timing_summary%s.rpt" $prefix $report_suffix]]',
            'set output_path [file join $report_dir [format "%s_diagnosis%s.json" $prefix $report_suffix]]',
        ):
            if text.count(fragment) != 1:
                raise SystemExit(f"{path}: current report fragment missing or ambiguous: {fragment}")

    text = replace_once(
        text,
        '    if {$phase in {opt place}} {',
        '    if {0 && $phase in {opt place}} {',
        path,
    )
    text = replace_once(
        text,
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
        path,
    )
    path.write_text(text)


def patch_physical_stage(path: Path) -> None:
    text = path.read_text()
    if '    set phase "place"' in text:
        open_checkpoint = "    open_checkpoint $input_dcp\n"
        aurora_gt_relocation = "\n".join(
            [
                open_checkpoint.rstrip(),
                '    if {[info exists cfg(peer_backend)] && $cfg(peer_backend) eq "aurora_qsfp1"} {',
                "        foreach {port pin} {",
                "            gt1_refclk_n M43 gt1_refclk_p M42",
                "            gt1_rxn_in[0] G54 gt1_rxn_in[1] F52 gt1_rxn_in[2] E54 gt1_rxn_in[3] D52",
                "            gt1_rxp_in[0] G53 gt1_rxp_in[1] F51 gt1_rxp_in[2] E53 gt1_rxp_in[3] D51",
                "            gt1_txn_out[0] G49 gt1_txn_out[1] E49 gt1_txn_out[2] C49 gt1_txn_out[3] A50",
                "            gt1_txp_out[0] G48 gt1_txp_out[1] E48 gt1_txp_out[2] C48 gt1_txp_out[3] A49",
                "        } {",
                "            set selected_port [get_ports -quiet [list $port]]",
                "            if {[llength $selected_port] != 1} {",
                '                error "Expected exactly one Aurora QSFP1 port $port, found [llength $selected_port]: $selected_port"',
                "            }",
                "            if {[get_property LOC $selected_port] ne $pin || [get_property PACKAGE_PIN $selected_port] ne $pin} {",
                "                reset_property LOC $selected_port",
                "                reset_property PACKAGE_PIN $selected_port",
                "                set_property PACKAGE_PIN $pin $selected_port",
                "                set_property LOC $pin $selected_port",
                "            }",
                "        }",
                "        foreach {channel_index expected_loc} {",
                "            3 GTYE4_CHANNEL_X0Y44 2 GTYE4_CHANNEL_X0Y45",
                "            1 GTYE4_CHANNEL_X0Y46 0 GTYE4_CHANNEL_X0Y47",
                "        } {",
                '            set channels [get_cells -hierarchical -quiet -filter "NAME =~ *inst_aurora*gen_channel_container\\[24\\].*gen_gtye4_channel_inst\\[$channel_index\\].GTYE4_CHANNEL_PRIM_INST"]',
                "            if {[llength $channels] != 1} {",
                '                error "Expected exactly one Aurora channel $channel_index, found [llength $channels]: $channels"',
                "            }",
                "            if {[get_property LOC $channels] ne $expected_loc} {",
                "                reset_property LOC $channels",
                "                set_property LOC $expected_loc $channels",
                "            }",
                "        }",
                "    }",
                "",
            ]
        )
        text = replace_once(text, open_checkpoint, aurora_gt_relocation, path)
        opt_case = re.search(
            r"(?ms)^        opt \{\n(?P<body>.*?)^        \}\n(?=        place \{\n)",
            text,
        )
        if opt_case is None:
            raise SystemExit(f"{path}: generated opt case was not found for combined placement")
        place_marker = "        place {\n"
        text = replace_once(
            text,
            place_marker,
            place_marker + opt_case.group("body"),
            path,
        )
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
