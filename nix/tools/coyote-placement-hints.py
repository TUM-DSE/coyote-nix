#!/usr/bin/env python3
"""Fail-closed consumer wrapper for declarative placement hints."""

import argparse
import json
import re
from pathlib import Path

CELL_RE = re.compile(r".+\Z", re.DOTALL)
SITE_RE = re.compile(r"[A-Z][A-Z0-9_]*_X[0-9]+Y[0-9]+\Z")
# Vivado Pblock identifiers accept underscores, but not hyphens.
NAME_RE = re.compile(r"[A-Za-z][A-Za-z0-9_]{0,47}\Z")


def fail(message):
    raise SystemExit(f"placement hints: {message}")


def overlaps(left, right):
    return left == right or left.startswith(right + "/") or right.startswith(left + "/")


def load_manifest(path):
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read manifest: {exc}")
    if not isinstance(data, dict) or set(data) != {"api", "groups"}:
        fail("manifest must contain only api and groups")
    if data["api"] != "coyote-nix.placement-hints/v1" or not isinstance(data["groups"], list) or not data["groups"]:
        fail("unsupported or empty manifest")
    names, cells, sites = set(), [], set()
    for group in data["groups"]:
        if not isinstance(group, dict) or set(group) != {"name", "cells", "sites"}:
            fail("each group must contain exactly name, cells, and sites")
        name, members, regions = group["name"], group["cells"], group["sites"]
        if not isinstance(name, str) or not NAME_RE.fullmatch(name) or name in names:
            fail("group names must be unique simple identifiers")
        names.add(name)
        if not isinstance(members, list) or not members or any(not isinstance(x, str) or not CELL_RE.fullmatch(x) or not x.isprintable() for x in members):
            fail("cell selectors must be nonempty exact printable hierarchical names")
        if len(set(members)) != len(members) or any(overlaps(left, right) for left in members for right in cells + members if left != right):
            fail("cell selectors must be unique, disjoint, and not contain one another")
        cells.extend(members)
        if not isinstance(regions, list) or not regions or any(not isinstance(x, str) or not SITE_RE.fullmatch(x) for x in regions):
            fail("site selectors must be nonempty exact site names")
        if len(set(regions)) != len(regions) or sites.intersection(regions):
            fail("site selectors must be unique and disjoint")
        sites.update(regions)
    return data


def tcl_word(value):
    """Emit one Tcl list element; escaped metacharacters cannot substitute or execute."""
    if not value or any(not char.isprintable() for char in value):
        fail("Tcl list elements must be nonempty printable strings")
    special = set(" \t{}[]$;\"\\")
    return "".join(("\\" + char) if char in special else char for char in value)


def emit_data(data):
    groups = []
    for group in data["groups"]:
        cells = " ".join(tcl_word(x) for x in group["cells"])
        sites = " ".join(tcl_word(x) for x in group["sites"])
        groups.append(f"[list {tcl_word(group['name'])} [list {cells}] [list {sites}]]")
    return "set ::coyote_placement_hint_groups [list " + " ".join(groups) + "]\n"


def inject(args):
    manifest = load_manifest(args.manifest)
    runner = Path(args.runner)
    text = runner.read_text()
    open_anchor = "    open_checkpoint $input_dcp\n"
    place_anchor = '            if {$place_directive ne ""} { place_design -directive $place_directive } else { place_design }\n'
    if (text.count(open_anchor) != 1 or text.count(place_anchor) != 1
            or text.count('set phase "place"') != 1):
        fail("generated Coyote place runner anchors do not match exactly; refusing to continue")
    apply_tcl = str(Path(args.apply_tcl))
    data_path = str(Path(args.data_output))
    for value in (apply_tcl, data_path):
        if any(char in value for char in "{}\\\n\r"):
            fail("unsafe path for Tcl injection")

    # The linked V80 flow imports the static DCP with SCOPED_TO_CELLS {inst_static}.
    # Protecting this exact hierarchy avoids loading a second checkpoint and tolerates
    # opt_design removing or renaming implementation primitives.
    apply_hook = (
        f'            source {{{apply_tcl}}}\n'
        f'            source {{{data_path}}}\n'
        "            coyote_apply_placement_hints\n"
        + place_anchor
    )
    text = text.replace(place_anchor, apply_hook, 1)
    runner.write_text(text)
    Path(args.data_output).write_text(emit_data(manifest))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    command = sub.add_parser("inject")
    command.add_argument("--runner", required=True)
    command.add_argument("--manifest", required=True)
    command.add_argument("--apply-tcl", required=True)
    command.add_argument("--data-output", required=True)
    command.set_defaults(func=inject)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
