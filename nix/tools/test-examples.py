"""Build Coyote's examples with Nix and keep the results in a run directory.

Usage: test-examples [--coyote REF] [--flake REF] [--jobs N] [--out DIR]
                     [--only REGEX] [--synth-only]

REF for a Coyote checkout needs its submodules, for example
git+file:///path/to/Coyote?ref=BRANCH&submodules=1.

Every piece of every example (host program, shell, application or one-piece
image) is built in a single `nix build --keep-going`, so shared shells are
built once and one failure does not stop the rest. Afterwards the run
directory holds:

  <board>/<example>/<piece>        link to each piece that built
  <board>/<example>/steps/<step>   link to each build step that built
  build.log, summary.md, summary.json

The links are garbage-collector roots: as long as the run directory exists,
Nix keeps everything it points to, and a later run reuses it.

--synth-only builds just the synthesis of every shell and one-piece example,
which needs nothing else and shows synthesis and configuration errors within
about two hours. Application synthesis needs its finished shell and is left
to the full run. It links the steps under synth/ and summarizes them.
"""

import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys

SYSTEM = "x86_64-linux"
TESTS = f"legacyPackages.{SYSTEM}.exampleTests"


def nix(*args, capture=True):
    result = subprocess.run(
        ["nix", "--extra-experimental-features", "nix-command flakes", *args],
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    if result.returncode != 0:
        sys.exit(f"test-examples: nix {' '.join(args[:2])} failed")
    return result.stdout


def coyote_revision(flake, coyote):
    if coyote:
        meta = json.loads(nix("flake", "metadata", "--json", coyote))
        rev = meta.get("revision") or meta.get("dirtyRevision") or "unknown"
    else:
        meta = json.loads(nix("flake", "metadata", "--json", flake))
        locked = meta["locks"]["nodes"]["coyote"]["locked"]
        rev = locked.get("rev", "unknown")
    return rev.replace("-dirty", "")[:8] + ("-dirty" if "dirty" in rev else "")


def evaluate(flake, overrides):
    apply = (
        "t: { sandboxPaths = t.sandboxPaths; pieces = builtins.mapAttrs "
        "(_: d: { drv = d.drvPath; out = d.outPath; }) t.pieces; }"
    )
    return json.loads(nix("eval", "--json", f"{flake}#{TESTS}", "--apply", apply, *overrides))


def build(pieces, sandbox_paths, jobs, log_path):
    if not pieces:
        pathlib.Path(log_path).write_text("")
        return 0
    command = [
        "nix", "--extra-experimental-features", "nix-command flakes",
        "build", "--no-link", "--keep-going", "-L", "--max-jobs", str(jobs),
    ]
    if sandbox_paths:
        command += ["--option", "extra-sandbox-paths", " ".join(sandbox_paths)]
    command += [f"{piece['drv']}^*" for piece in pieces.values()]
    with open(log_path, "w") as log:
        process = subprocess.Popen(command, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT)
        for line in process.stdout:
            log.write(line)
            if re.match(r"(error: |\S+> buildPhase completed)", line):
                print(line, end="", flush=True)
        return process.wait()


def failed_derivations(log_path):
    """Derivations whose own builder failed, as opposed to a dependency."""
    failed, current = set(), None
    for line in open(log_path):
        found = re.match(r"error: Cannot build '(/nix/store/[^']+\.drv)'", line)
        if found:
            current = found.group(1)
        elif current and "Reason: builder failed" in line:
            failed.add(current)
            current = None
    return failed


def coyote_steps(drv):
    """The Coyote build steps in a derivation's build closure, as drv paths."""
    closure = subprocess.run(["nix-store", "-qR", drv], text=True,
                             stdout=subprocess.PIPE, check=True).stdout.split()
    return [d for d in closure
            if d.endswith(".drv") and re.match(r"/nix/store/[^-]+-coyote-", d)]


def outputs(drv):
    return subprocess.run(["nix-store", "-q", "--outputs", drv], text=True,
                          stdout=subprocess.PIPE, check=True).stdout.split()


def step_name(drv):
    return re.sub(r"^/nix/store/[^-]+-|\.drv$", "", drv)


def add_root(link, path):
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.is_symlink() or link.exists():
        link.unlink()
    subprocess.run(["nix-store", "--add-root", str(link), "--indirect", "--realise", path],
                   stdout=subprocess.DEVNULL, check=True)


def validation(out):
    path = pathlib.Path(out, "metadata", "validation.json")
    if not path.exists():
        return None
    data = json.loads(path.read_text())
    return {"outcome": data.get("outcome"), "reasons": data.get("reasons", [])}


def log_tail(drv, lines=30):
    log = subprocess.run(["nix", "--extra-experimental-features", "nix-command", "log", drv],
                         text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
    return log.splitlines()[-lines:]


SYNTH_STEP = re.compile(r"/nix/store/[^-]+-coyote-(shell|example)-.*-synth-[0-9.]+\.drv$")


def synthesis_steps(pieces):
    steps = set()
    for piece in pieces.values():
        steps.update(d for d in coyote_steps(piece["drv"]) if SYNTH_STEP.match(d))
    return {step_name(d): {"drv": d, "out": outputs(d)[0]} for d in sorted(steps)}


def summarize_synthesis(run, steps, failed):
    report, lines = {}, [f"# Coyote synthesis run {run.name}", "", "| Step | Result |",
                         "| --- | --- |"]
    for name, step in sorted(steps.items()):
        if os.path.exists(step["out"]):
            result = "ok"
        elif step["drv"] in failed:
            result = "failed"
        else:
            result = "not built (a dependency failed)"
        report[name] = {"result": result}
        lines.append(f"| {name} | {result} |")
    for name, step in sorted(steps.items()):
        if report[name]["result"] == "failed":
            report[name]["log"] = log_tail(step["drv"])
            lines += ["", f"## {name}", "", "```", *report[name]["log"], "```"]
    (run / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    (run / "summary.md").write_text("\n".join(lines) + "\n")
    return report


def summarize(run, pieces, failed):
    examples = {}
    for name, piece in pieces.items():
        board, example, kind = name.split("/")
        examples.setdefault(f"{board}/{example}", {})[kind] = piece

    report = {}
    for key, kinds in sorted(examples.items()):
        built = {k: os.path.exists(p["out"]) for k, p in kinds.items()}
        entry = {"pieces": built}
        for kind in ("app", "hw", "shell"):
            if kind in kinds and built[kind]:
                entry.setdefault("validation", {})[kind] = validation(kinds[kind]["out"])
        steps = set()
        for piece in kinds.values():
            steps.update(coyote_steps(piece["drv"]))
        broken = sorted(failed & steps)
        if broken:
            entry["failed"] = [{"step": step_name(d), "drv": d, "log": log_tail(d)}
                               for d in broken]
        if all(built.values()):
            rejected = [k for k, v in entry.get("validation", {}).items()
                        if v and v["outcome"] != "accepted"]
            entry["result"] = ("built, validation rejected: " + ", ".join(rejected)
                               if rejected else "ok")
        elif broken:
            entry["result"] = "failed at " + ", ".join(step_name(d) for d in broken)
        else:
            entry["result"] = "not built"
        report[key] = entry

    (run / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = [f"# Coyote example run {run.name}", "", "| Example | Result | Details |",
             "| --- | --- | --- |"]
    for key, entry in report.items():
        details = []
        for kind, result in entry.get("validation", {}).items():
            if result and result["reasons"]:
                details.append(f"{kind}: " + "; ".join(result["reasons"]))
        lines.append(f"| {key} | {entry['result']} | {'<br>'.join(details)} |")
    for key, entry in report.items():
        for failure in entry.get("failed", []):
            lines += ["", f"## {key}: {failure['step']}", "", "```",
                      *failure["log"], "```"]
    (run / "summary.md").write_text("\n".join(lines) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--coyote", help="Coyote flake reference to build against "
                        "(default: coyote-nix's pinned Coyote)")
    parser.add_argument("--flake", default=os.environ.get("COYOTE_NIX_FLAKE", "."),
                        help="coyote-nix flake to use (default: .)")
    parser.add_argument("--jobs", type=int, default=6, help="parallel builds (default: 6)")
    parser.add_argument("--out", default="coyote-example-runs",
                        help="directory for run directories (default: ./coyote-example-runs)")
    parser.add_argument("--only", help="build only pieces whose <board>/<example>/<piece> "
                        "name matches this regular expression")
    parser.add_argument("--synth-only", action="store_true",
                        help="build only the synthesis of shells and one-piece examples")
    args = parser.parse_args()

    overrides = ["--override-input", "coyote", args.coyote] if args.coyote else []
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M")
    kind = "-synth" if args.synth_only else ""
    run = (pathlib.Path(args.out).resolve()
           / f"{stamp}-coyote-{coyote_revision(args.flake, args.coyote)}{kind}")
    run.mkdir(parents=True)
    latest = run.parent / "latest"
    if latest.is_symlink():
        latest.unlink()
    latest.symlink_to(run.name)
    print(f"test-examples: run directory {run}", flush=True)

    tests = evaluate(args.flake, overrides)
    pieces = {name: piece for name, piece in tests["pieces"].items()
              if not args.only or re.search(args.only, name)}
    (run / "pieces.json").write_text(json.dumps(pieces, indent=2) + "\n")

    if args.synth_only:
        steps = synthesis_steps(pieces)
        status = build(steps, tests["sandboxPaths"], args.jobs, run / "build.log")
        for name, step in steps.items():
            if os.path.exists(step["out"]):
                add_root(run / "synth" / name, step["out"])
        report = summarize_synthesis(run, steps, failed_derivations(run / "build.log"))
        ok = sum(1 for entry in report.values() if entry["result"] == "ok")
        print(f"test-examples: {ok} of {len(report)} synthesis steps ok; "
              f"see {run / 'summary.md'}")
        return 0 if status == 0 else 1

    status = build(pieces, tests["sandboxPaths"], args.jobs, run / "build.log")

    for name, piece in pieces.items():
        if os.path.exists(piece["out"]):
            add_root(run / name, piece["out"])
        board, example, _ = name.split("/")
        for drv in coyote_steps(piece["drv"]):
            for out in outputs(drv):
                if os.path.exists(out):
                    add_root(run / board / example / "steps" / step_name(drv), out)

    report = summarize(run, pieces, failed_derivations(run / "build.log"))
    ok = sum(1 for entry in report.values() if entry["result"] == "ok")
    print(f"test-examples: {ok} of {len(report)} examples ok; see {run / 'summary.md'}")
    return 0 if status == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
