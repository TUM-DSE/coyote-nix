import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "nix/tools/coyote-compare-physical.py"
STAGE_TOOL = ROOT / "nix/tools/coyote-implementation-stage.py"
FIXTURES = ROOT / "tests/fixtures/strict-signoff"
spec = importlib.util.spec_from_file_location("compare", TOOL)
compare_tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare_tool)


class PhysicalComparisonTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.context_without_id = {
            "board": "v80", "architecture": "versal", "part": "xcv80-fixture",
            "flow": "app", "sourceId": "source-fixture",
            "constraintsId": "constraints-fixture", "toolId": "vivado-fixture",
            "toolVersion": "2025.1",
        }
        encoded = json.dumps(self.context_without_id, sort_keys=True, separators=(",", ":")).encode()
        self.context = dict(self.context_without_id, id=hashlib.sha256(encoded).hexdigest())

    def tearDown(self):
        self.temp.cleanup()

    def make_stage(self, name, phase, predecessor=None, outcome="complete", wns=None):
        stage = self.root / name
        (stage / "reports").mkdir(parents=True)
        (stage / "checkpoints").mkdir()
        (stage / "checkpoints" / f"{phase}.dcp").write_text(f"{phase} checkpoint")
        timing = stage / "reports" / "timing_summary.rpt"
        raw = (FIXTURES / "timing-summary.rpt").read_text()
        if wns is not None:
            raw = raw.replace("0.125        0.000", f"{wns:0.3f}        0.000").replace("fixture_clk 0.125", f"fixture_clk {wns:0.3f}")
        timing.write_text(raw)
        route = stage / "reports" / "route_status.rpt"
        route.write_text((FIXTURES / "route-status.rpt").read_text())
        drc = stage / "reports" / "drc.rpt"
        drc.write_text((FIXTURES / "drc.rpt").read_text())
        validation = stage / "reports" / "validation.json"
        checkpoint_role = "validated-checkpoint" if phase == "validate" else f"{phase}-checkpoint"
        artifacts = [
            {"role": checkpoint_role, "path": f"checkpoints/{phase}.dcp"},
            {"role": f"{phase}-timing-summary-report", "path": "reports/timing_summary.rpt"},
            {"role": f"{phase}-route-status-report", "path": "reports/route_status.rpt"},
            {"role": f"{phase}-drc-report", "path": "reports/drc.rpt"},
        ]
        if phase == "validate":
            validation.write_text(json.dumps({"outcome": outcome, "reasons": []}) + "\n")
            artifacts.append({"role": "validation-result", "path": "reports/validation.json"})
        spec = {
            "phase": phase, "unit": "config_0", "context": self.context,
            "strategy": {"directive": "fixture"}, "resources": {},
            "outcome": outcome, "artifacts": artifacts,
        }
        if predecessor is not None:
            spec["predecessorPath"] = str(predecessor)
        spec_path = self.root / f"{name}.json"
        spec_path.write_text(json.dumps(spec))
        subprocess.run([sys.executable, str(STAGE_TOOL), "write", str(spec_path), str(stage), str(stage)], check=True)
        return stage

    def chain_to_validation(self, name, validation_outcome="rejected", wns=None):
        inputs = self.make_stage(f"{name}-inputs", "inputs")
        link = self.make_stage(f"{name}-link", "link", inputs)
        place = self.make_stage(f"{name}-place", "place", link)
        route = self.make_stage(f"{name}-route", "route", place)
        return self.make_stage(f"{name}-validate", "validate", route, validation_outcome, wns)

    def test_cli_reads_real_validated_stage_dirs_and_vivado_clock(self):
        before = self.chain_to_validation("before", wns=0.125)
        after = self.chain_to_validation("after", wns=0.250)
        output = self.root / "comparison.json"
        result = subprocess.run([sys.executable, str(TOOL), str(before), str(after), "--json", str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        comparison = json.loads(output.read_text())
        self.assertTrue(comparison["comparable"])
        clock = comparison["clockComparison"]["fixture_clk"]
        self.assertEqual(clock["before"]["periodNs"], 4.0)
        self.assertEqual(clock["before"]["wnsNs"], 0.125)
        self.assertEqual(clock["delta"]["wnsNs"], 0.125)
        self.assertEqual(comparison["before"]["outcome"], "rejected")
        self.assertEqual(comparison["before"]["route"]["metrics"]["fullyRoutedNets"], 10)
        self.assertIn("validate-drc-report", comparison["before"]["drc"]["reports"])

    def test_manifest_hash_tampering_fails_before_comparison_output(self):
        before = self.chain_to_validation("tamper-before")
        after = self.chain_to_validation("tamper-after")
        timing_report = before / "reports" / "timing_summary.rpt"
        timing_report.write_text(timing_report.read_text() + "tampered\\n")
        output = self.root / "must-not-exist.json"
        result = subprocess.run([sys.executable, str(TOOL), str(before), str(after), "--json", str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("artifact hash mismatch", result.stderr)
        self.assertFalse(output.exists())

    def test_clock_period_mismatch_is_noncomparable(self):
        before = self.chain_to_validation("period-before")
        after = self.chain_to_validation("period-after")
        report = after / "reports" / "timing_summary.rpt"
        report.write_text(report.read_text().replace("4.000       250.000", "5.000       200.000"))
        # Recreate the stage through the manifest writer so the changed report has valid declared hashes.
        manifest = json.loads((after / "metadata" / "stage.json").read_text())
        spec = {
            "phase": manifest["phase"], "unit": manifest["unit"], "context": manifest["context"],
            "strategy": manifest["strategy"], "resources": manifest["resources"],
            "outcome": manifest["outcome"], "predecessorPath": str(self.root / "period-after-route"),
            "artifacts": [{"role": item["role"], "path": item["path"]} for item in manifest["artifacts"]],
        }
        spec_path = self.root / "period-after-validate.json"
        spec_path.write_text(json.dumps(spec))
        subprocess.run([sys.executable, str(STAGE_TOOL), "write", str(spec_path), str(after), str(after)], check=True)
        output = self.root / "period-comparison.json"
        result = subprocess.run([sys.executable, str(TOOL), str(before), str(after), "--json", str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        comparison = json.loads(output.read_text())
        self.assertFalse(comparison["comparability"]["clockPeriods"])
        self.assertEqual(comparison["before"]["clocks"]["fixture_clk"]["periodNs"], 4.0)
        self.assertEqual(comparison["after"]["clocks"]["fixture_clk"]["periodNs"], 5.0)

    def test_place_and_route_stages_are_not_comparable(self):
        inputs = self.make_stage("place-inputs", "inputs")
        link = self.make_stage("place-link", "link", inputs)
        place = self.make_stage("actual-place", "place", link)
        route_inputs = self.make_stage("route-inputs", "inputs")
        route_link = self.make_stage("route-link", "link", route_inputs)
        route_place = self.make_stage("route-place", "place", route_link)
        route = self.make_stage("actual-route", "route", route_place)
        output = self.root / "stage-mismatch.json"
        result = subprocess.run([sys.executable, str(TOOL), str(place), str(route), "--json", str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        self.assertFalse(json.loads(output.read_text())["comparability"]["stage"])

    def test_all_declared_drc_reports_are_visible(self):
        implementation = self.root / "implementation.rpt"
        bitstream = self.root / "bitstream.rpt"
        implementation.write_text((FIXTURES / "drc.rpt").read_text())
        bitstream.write_text(implementation.read_text().replace("Warning", "Error"))
        _, drc = compare_tool.parse_diagnostics({
            "drc-report": implementation, "bitstream-drc-report": bitstream,
        })
        self.assertEqual(len(drc["reports"]), 2)
        self.assertGreater(drc["reports"]["bitstream-drc-report"]["metrics"]["errors"], 0)

    def test_missing_intra_clock_metrics_are_not_replaced_by_overall(self):
        before = self.chain_to_validation("missing-intra")
        after = self.chain_to_validation("complete")
        timing = before / "reports/timing_summary.rpt"
        timing.write_text(timing.read_text().split("| Intra Clock Table")[0])
        subprocess.run([
            sys.executable, str(STAGE_TOOL), "write",
            str(self.root / "missing-intra-validate.json"), str(before), str(before),
        ], check=True)
        observed = compare_tool.read_stage(before)
        self.assertIsNone(observed["clocks"]["fixture_clk"].get("wnsNs"))
        self.assertFalse(compare_tool.compare(observed, compare_tool.read_stage(after))["comparable"])

    def test_differing_clock_sets_are_safe_and_noncomparable(self):
        base = {"stage": "route", "tool": "v", "toolVersion": "1", "part": "p", "sourceId": "s", "constraintsId": "c", "clocks": {"a": {"periodNs": 4.0}}, "route": {}, "drc": {}}
        other = dict(base, clocks={"b": {"periodNs": 3.0}})
        result = compare_tool.compare(base, other)
        self.assertFalse(result["comparable"])
        self.assertIsNone(result["clockComparison"]["a"]["after"])
        self.assertIsNone(result["clockComparison"]["a"]["delta"])

    def test_empty_clock_rows_are_noncomparable(self):
        base = {"stage": "route", "tool": "v", "toolVersion": "1", "part": "p", "sourceId": "s", "constraintsId": "c", "clocks": {"clk": {"periodNs": None}}, "route": {}, "drc": {}}
        result = compare_tool.compare(base, base)
        self.assertFalse(result["comparable"])
        self.assertFalse(result["comparability"]["clockMetrics"])

    def test_nonfinite_clock_metric_is_unavailable_not_arithmetic(self):
        self.assertIsNone(compare_tool.finite_decimal("NaN", "test"))
        self.assertIsNone(compare_tool.finite_decimal("Infinity", "test"))


if __name__ == "__main__":
    unittest.main()
