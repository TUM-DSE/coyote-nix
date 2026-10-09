import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

TOOL = Path(__file__).parents[1] / "nix/tools/coyote-retain-physical.py"
spec = importlib.util.spec_from_file_location("retain_physical", TOOL)
retain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retain)
STORE = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-physical-stage"


def record(checkpoint_hash="a" * 64):
    return {
        "storePath": STORE, "phase": "route", "unit": "config_0", "contextId": "e" * 64,
        "manifestId": "b" * 64, "recipeId": "c" * 64,
        "checkpoint": {"role": "routed-checkpoint", "path": "checkpoints/route.dcp", "sha256": checkpoint_hash},
    }


class RetainPhysicalTests(unittest.TestCase):
    def test_check_distinguishes_missing_path_and_dangling_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            inventory = root / "inventory.json"
            inventory.write_text(json.dumps({"api": retain.INVENTORY_API, "stages": [record()]}))
            output = io.StringIO()
            with patch.object(retain, "store_path_valid", return_value=False), \
                 patch.object(retain, "registered_roots", return_value=set()), \
                 contextlib.redirect_stdout(output):
                status = retain.check(inventory, root / "roots")
            self.assertEqual(status, 1)
            self.assertIn("MISSING GC ROOT:", output.getvalue())
            self.assertIn("MISSING STORE PATH:", output.getvalue())

    def test_check_reports_dangling_gc_root_for_missing_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            inventory = root / "inventory.json"
            inventory.write_text(json.dumps({"api": retain.INVENTORY_API, "stages": [record()]}))
            roots = root / "roots"
            roots.mkdir()
            (roots / retain.root_name(STORE)).symlink_to(STORE)
            output = io.StringIO()
            with patch.object(retain, "store_path_valid", return_value=False), \
                 patch.object(retain, "registered_roots", return_value=set()), \
                 contextlib.redirect_stdout(output):
                status = retain.check(inventory, roots)
            self.assertEqual(status, 1)
            self.assertIn("DANGLING GC ROOT:", output.getvalue())
            self.assertIn("MISSING STORE PATH:", output.getvalue())

    def test_check_reports_checkpoint_hash_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            inventory = root / "inventory.json"
            inventory.write_text(json.dumps({"api": retain.INVENTORY_API, "stages": [record()]}))
            roots = root / "roots"
            roots.mkdir()
            (roots / retain.root_name(STORE)).symlink_to(STORE)
            output = io.StringIO()
            with patch.object(retain, "store_path_valid", return_value=True), \
                 patch.object(retain, "registered_roots", return_value={str((roots / retain.root_name(STORE)).absolute())}), \
                 patch.object(retain, "stage_record", return_value=record("d" * 64)), \
                 contextlib.redirect_stdout(output):
                status = retain.check(inventory, roots)
            self.assertEqual(status, 1)
            self.assertIn("HASH/manifest/inventory mismatch:", output.getvalue())

    def test_check_detects_wrong_symlink_for_missing_store_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            inventory = root / "inventory.json"
            inventory.write_text(json.dumps({"api": retain.INVENTORY_API, "stages": [record()]}))
            roots = root / "roots"
            roots.mkdir()
            link = roots / retain.root_name(STORE)
            link.symlink_to("/nix/store/wrong-target")
            output = io.StringIO()
            with patch.object(retain, "store_path_valid", return_value=False), \
                 patch.object(retain, "registered_roots", return_value=set()), \
                 contextlib.redirect_stdout(output):
                retain.check(inventory, roots)
            self.assertIn("WRONG GC ROOT:", output.getvalue())
            self.assertIn("MISSING STORE PATH:", output.getvalue())

    def test_check_rejects_tampered_inventory_identity_fields(self):
        mutations = {
            "phase": "place", "unit": "other_unit", "contextId": "f" * 64,
            "recipeId": "d" * 64,
        }
        for key, value in mutations.items():
            with self.subTest(field=key), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                inventory = root / "inventory.json"
                claimed = record()
                claimed[key] = value
                inventory.write_text(json.dumps({"api": retain.INVENTORY_API, "stages": [claimed]}))
                roots = root / "roots"
                roots.mkdir()
                (roots / retain.root_name(STORE)).symlink_to(STORE)
                output = io.StringIO()
                registered = {str((roots / retain.root_name(STORE)).absolute())}
                with patch.object(retain, "store_path_valid", return_value=True), \
                     patch.object(retain, "registered_roots", return_value=registered), \
                     patch.object(retain, "stage_record", return_value=record()), \
                     contextlib.redirect_stdout(output):
                    status = retain.check(inventory, roots)
                self.assertEqual(status, 1)
                self.assertIn("HASH/manifest/inventory mismatch:", output.getvalue())

    def test_read_inventory_rejects_top_level_array_and_empty_stages(self):
        with tempfile.TemporaryDirectory() as tmp:
            inventory = Path(tmp) / "inventory.json"
            for document, message in (([], "unsupported or malformed"),
                                       ({"api": retain.INVENTORY_API, "stages": []}, "contains no stages")):
                inventory.write_text(json.dumps(document))
                with self.subTest(document=document), self.assertRaisesRegex(ValueError, message):
                    retain.read_inventory(inventory)

    def test_read_inventory_rejects_bad_stage_entries_and_checkpoint_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            inventory = Path(tmp) / "inventory.json"
            bad_documents = [
                {"api": retain.INVENTORY_API, "stages": [42]},
                {"api": retain.INVENTORY_API, "stages": [record(), record()]},
            ]
            bad_hash = record()
            bad_hash["checkpoint"]["sha256"] = "not-a-hash"
            bad_documents.append({"api": retain.INVENTORY_API, "stages": [bad_hash]})
            bad_path = record()
            bad_path["checkpoint"]["path"] = "../escape.dcp"
            bad_documents.append({"api": retain.INVENTORY_API, "stages": [bad_path]})
            for document in bad_documents:
                inventory.write_text(json.dumps(document))
                with self.subTest(document=document), self.assertRaises(ValueError):
                    retain.read_inventory(inventory)

    def test_check_detects_unregistered_nix_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            inventory = root / "inventory.json"
            inventory.write_text(json.dumps({"api": retain.INVENTORY_API, "stages": [record()]}))
            roots = root / "roots"
            roots.mkdir()
            (roots / retain.root_name(STORE)).symlink_to(STORE)
            output = io.StringIO()
            with patch.object(retain, "store_path_valid", return_value=True), \
                 patch.object(retain, "registered_roots", return_value=set()), \
                 patch.object(retain, "stage_record", return_value=record()), \
                 contextlib.redirect_stdout(output):
                retain.check(inventory, roots)
            self.assertIn("UNREGISTERED GC ROOT:", output.getvalue())

    def test_retain_registers_root_with_nix_store(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            roots = root / "inventory.roots"
            inventory = root / "inventory.json"

            def nix_store(args, **kwargs):
                if "--add-root" in args:
                    Path(args[5]).symlink_to(args[-1])
                    return type("Result", (), {"returncode": 0, "stdout": "", "stderr": ""})()
                return type("Result", (), {
                    "returncode": 0,
                    "stdout": f'{roots / retain.root_name(STORE)} -> {STORE}\n',
                    "stderr": "",
                })()

            with patch.object(retain, "stage_record", return_value=record()), \
                 patch.object(retain, "store_path_valid", return_value=True), \
                 patch.object(retain.subprocess, "run", side_effect=nix_store) as run:
                retain.retain([STORE], inventory, roots)
            add_call = next(call.args[0] for call in run.call_args_list if "--add-root" in call.args[0])
            self.assertEqual(add_call[1:4], ["--option", "substitute", "false"])
            self.assertEqual(add_call[4:7], ["--add-root", str(roots / retain.root_name(STORE)), "--indirect"])
            self.assertEqual(add_call[7:], ["--realise", STORE])
            query_call = next(call.args[0] for call in run.call_args_list if "--query" in call.args[0])
            self.assertEqual(query_call, ["nix-store", "--query", "--roots", STORE])
            self.assertTrue(inventory.exists())

    def test_stage_identity_uses_existing_manifest_validator(self):
        with tempfile.TemporaryDirectory() as tmp:
            stage = Path(tmp) / "stage"
            checkpoint = stage / "checkpoints/route.dcp"
            checkpoint.parent.mkdir(parents=True)
            checkpoint.write_bytes(b"routed checkpoint fixture")
            spec_path = stage / "spec.json"
            stage_validator = retain.stage_module()
            context = {
                "board": "fixture", "architecture": "test", "part": "part",
                "flow": "flow", "sourceId": "src", "constraintsId": "xdc", "toolId": "tool",
            }
            context["id"] = hashlib.sha256(stage_validator.canonical(context).rstrip(b"\n")).hexdigest()
            spec_path.write_text(json.dumps({
                "phase": "inputs", "unit": "config_0", "context": context,
                "artifacts": [{"role": "inputs-checkpoint", "path": "checkpoints/route.dcp"}],
            }))
            retain.stage_module().write_manifest(spec_path, stage, stage)
            with patch.object(retain, "valid_store_path", return_value=str(stage)):
                result = retain.stage_record("ignored")
            manifest = retain.stage_module().validate_manifest(stage)
            self.assertEqual(result["manifestId"], manifest["manifestId"])
            self.assertEqual(result["checkpoint"]["sha256"], manifest["artifacts"][0]["sha256"])

    def test_retain_refuses_existing_inventory_without_touching_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            inventory = root / "inventory.json"
            inventory.write_text("owned by someone else")
            with self.assertRaisesRegex(ValueError, "refusing to overwrite existing inventory"):
                retain.retain([STORE], inventory, root / "roots")
            self.assertEqual(inventory.read_text(), "owned by someone else")
            self.assertFalse((root / "roots").exists())

    def test_retain_roots_only_valid_existing_store_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch.object(retain, "stage_record", return_value=record()), \
                 patch.object(retain, "store_path_valid", return_value=False):
                with self.assertRaisesRegex(ValueError, "refusing to build or download"):
                    retain.retain([STORE], root / "inventory.json", root / "roots")
            self.assertFalse((root / "roots").exists())
            self.assertFalse((root / "inventory.json").exists())


if __name__ == "__main__":
    unittest.main()
