import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "reference", Path(__file__).parents[1] / "nix/tools/check-subdivision-reference.py"
)
reference = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reference)


class ReferenceTest(unittest.TestCase):
    def test_integrity_and_static_compatibility(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ("parent", "static", "current")]
            for path, content in zip(paths, (b"implemented parent", b"static", b"static")):
                path.write_bytes(content)
            args = (paths[0], reference.digest(paths[0]), paths[1], reference.digest(paths[1]), paths[2])
            reference.verify(*args)
            for index in range(3):
                original = paths[index].read_bytes()
                paths[index].write_bytes(b"different")
                with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
                    reference.verify(*args)
                paths[index].write_bytes(original)


if __name__ == "__main__":
    unittest.main()
