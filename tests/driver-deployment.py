"""Deployment safety at command boundaries; never accesses real PCI/module state.

Usage: python3 tests/driver-deployment.py <repository-root>
The fixture relocates literal sysfs paths in copies, not via a production override.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1)).resolve()
BDF = "0000:ab:00.0"


class Deployment(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.sys = self.root / "sys"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.endpoint = self.sys / "bus/pci/devices" / BDF
        self.endpoint.mkdir(parents=True)
        self.driver = self.sys / "bus/pci/drivers/coyote_driver"
        self.driver.mkdir(parents=True)
        self.log = self.root / "mutations"
        self.ko = self.root / "renamed.ko"
        self.ko.touch()
        self.image = self.root / "full.bit"
        self.image.touch()
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        FPGA_BDF="AB:00.0", TARGET_PLATFORM="ultrascale_plus",
                        NAME="coyote_driver", VERMAGIC="6.12.85 SMP preempt mod_unload ",
                        RELEASE="6.12.85", LOG=str(self.log), FIXTURE=str(self.root),
                        COYOTE_NIX_INSERT_DRIVER_READY_TIMEOUT_S="0")
        for key in ("COYOTE_DRIVER_ARGS", "IMAGE_HINT", "FPGA_BITSTREAM"):
            self.env.pop(key, None)
        common = (ROOT / "nix/tools/coyote-common.sh").read_text()
        common = common.replace("/sys/", f"{self.sys}/")
        # Package resolution is non-hardware input; use the same explicit fixture
        # module for deploy-hw as for insert-driver.
        common += f'\nresolve_default_driver_ko_from_package() {{ echo "{self.ko}"; }}\n'
        for tool in ("insert-driver", "unload-driver", "deploy-hw"):
            body = (ROOT / f"nix/tools/{tool}.sh").read_text()
            self.script(tool, common + body.replace("/sys/", f"{self.sys}/"))
        self.script("modinfo", 'case "$2" in\nname) printf "%s\\n" "$NAME"; exit "${NAME_RC:-0}";;\nvermagic) printf "%s\\n" "$VERMAGIC"; exit "${VERMAGIC_RC:-0}";;\nesac')
        self.script("uname", 'printf "%s\\n" "$RELEASE"; exit "${UNAME_RC:-0}"')
        self.script("sudo", 'exec "$@"')
        # Force the tee branch, so unbind writes/failures are observable too.
        self.script("id", 'echo 1000')
        self.script("tee", '''echo unbind >> "$LOG"
if [ "${UNBIND_FAIL:-0}" = 1 ]; then exit 23; fi
read -r bdf
rm "$FIXTURE/sys/bus/pci/devices/$bdf/driver"
rm "$FIXTURE/sys/bus/pci/drivers/coyote_driver/$bdf"
''')
        self.script("rmmod", '''echo rmmod >> "$LOG"
if [ "${RMMOD_FAIL:-0}" = 1 ]; then exit 24; fi
rm -rf "$FIXTURE/sys/module/coyote_driver"
''')
        self.script("insmod", '''echo insmod >> "$LOG"
mkdir -p "$FIXTURE/sys/module/coyote_driver"
if [ "${NO_BIND:-0}" != 1 ]; then
  ln -s "$FIXTURE/sys/bus/pci/drivers/coyote_driver" "$FIXTURE/sys/bus/pci/devices/$FPGA_BDF/driver"
  ln -s "$FIXTURE/sys/bus/pci/devices/$FPGA_BDF" "$FIXTURE/sys/bus/pci/drivers/coyote_driver/$FPGA_BDF"
fi
exit "${INSMOD_RC:-0}"
''')
        for command in ("hot-reset", "program-cli", "set-hugepages", "modprobe"):
            self.script(command, f'echo {command} >> "$LOG"')

    def script(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{shutil.which('bash')}\nset -euo pipefail\n" + body + "\n")
        path.chmod(0o755)

    def bind(self, bdf=BDF, owner="coyote_driver"):
        driver = self.sys / "bus/pci/drivers" / owner
        driver.mkdir(parents=True, exist_ok=True)
        endpoint = self.sys / "bus/pci/devices" / bdf
        endpoint.mkdir(parents=True, exist_ok=True)
        (endpoint / "driver").symlink_to(driver)
        (driver / bdf).symlink_to(endpoint)
        (self.sys / "module" / owner).mkdir(parents=True, exist_ok=True)

    def run_tool(self, tool, rc=None):
        args = {"insert-driver": [str(self.ko)], "deploy-hw": [str(self.image)],
                "unload-driver": []}[tool]
        result = subprocess.run([str(self.bin / tool), *args], env=self.env,
                                text=True, capture_output=True, timeout=10)
        if rc is None:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertEqual(result.returncode, rc, result.stdout + result.stderr)
        return result

    def mutations(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def reject_both(self):
        for tool in ("insert-driver", "deploy-hw"):
            with self.subTest(tool=tool):
                self.run_tool(tool)
                self.assertEqual(self.mutations(), [])

    def test_bad_module_and_kernel_metadata(self):
        cases = [("NAME", x) for x in ("", "foreign", "coyote_driver\nforeign")]
        cases += [("VERMAGIC", x) for x in ("", " ", "6.12.84 SMP", "6.12.85\nSMP", "6.12.85/bad SMP")]
        cases += [("RELEASE", x) for x in ("", " ", "6.12.85 extra", "6.12.85\n6.12.85", "-bad")]
        cases += [(x, "1") for x in ("NAME_RC", "VERMAGIC_RC", "UNAME_RC")]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                original = self.env.copy()
                self.env[key] = value
                self.reject_both()
                self.env = original

    def test_missing_module(self):
        self.ko.unlink()
        self.reject_both()

    def test_invalid_bdf(self):
        for value in ("", "../ab:00.0", "ab:20.0", "ab:00.8", "ab:0.0", "00000:ab:00.0"):
            with self.subTest(bdf=value):
                self.env["FPGA_BDF"] = value
                self.reject_both()
                self.run_tool("unload-driver")
                self.assertEqual(self.mutations(), [])

    def test_absent_endpoint(self):
        self.endpoint.rmdir()
        self.reject_both()
        self.run_tool("unload-driver")
        self.assertEqual(self.mutations(), [])

    def test_foreign_endpoint(self):
        self.bind(owner="foreign")
        self.reject_both()
        self.run_tool("unload-driver")
        self.assertEqual(self.mutations(), [])
        self.assertTrue((self.endpoint / "driver").is_symlink())

    def test_loaded_insert_requires_explicit_reload(self):
        (self.sys / "module/coyote_driver").mkdir(parents=True)
        self.run_tool("insert-driver")
        self.assertEqual(self.mutations(), [])

    def test_bound_insert_requires_explicit_reload(self):
        self.bind()
        self.run_tool("insert-driver")
        self.assertEqual(self.mutations(), [])

    def test_unload_isolation(self):
        self.bind()
        self.bind("0000:ac:00.0")
        for tool in ("unload-driver", "deploy-hw"):
            self.run_tool(tool)
            self.assertEqual(self.mutations(), [])
            self.assertTrue((self.endpoint / "driver").is_symlink())

    def test_unbind_failure_stops_before_rmmod(self):
        self.bind()
        self.env["UNBIND_FAIL"] = "1"
        self.run_tool("unload-driver", 23)
        self.assertEqual(self.mutations(), ["unbind"])

    def test_rmmod_failure_propagates(self):
        self.bind()
        self.env["RMMOD_FAIL"] = "1"
        self.run_tool("unload-driver", 24)
        self.assertEqual(self.mutations(), ["unbind", "rmmod"])

    def test_unload_selected_only(self):
        self.bind()
        self.bind("0000:ac:00.0", "foreign")
        self.run_tool("unload-driver", 0)
        self.assertEqual(self.mutations(), ["unbind", "rmmod"])
        self.assertTrue((self.sys / "bus/pci/devices/0000:ac:00.0/driver").is_symlink())

    def test_unload_absent_module_is_noop(self):
        self.run_tool("unload-driver", 0)
        self.assertEqual(self.mutations(), [])

    def test_architecture_vermagic_flags_are_not_release_policy(self):
        self.env["VERMAGIC"] = "6.12.85 SMP aarch64 arch:flag "
        self.run_tool("insert-driver", 0)
        self.assertEqual(self.mutations(), ["insmod"])

    def test_insert_normalizes_bdf_and_uses_actual_name(self):
        self.run_tool("insert-driver", 0)
        self.assertEqual(self.mutations(), ["insmod"])
        self.assertTrue((self.endpoint / "driver").is_symlink())

    def test_insmod_failure_even_if_binding_appears(self):
        self.env["INSMOD_RC"] = "17"
        self.run_tool("insert-driver", 17)
        self.assertEqual(self.mutations(), ["insmod"])

    def test_insmod_failure_without_binding(self):
        self.env.update(INSMOD_RC="18", NO_BIND="1")
        self.run_tool("insert-driver", 18)
        self.assertEqual(self.mutations(), ["insmod"])

    def test_successful_insmod_without_binding_is_failure(self):
        self.env["NO_BIND"] = "1"
        self.run_tool("insert-driver")
        self.assertEqual(self.mutations(), ["insmod"])

    def test_deploy_stops_on_unload_failure(self):
        self.bind()
        self.env["RMMOD_FAIL"] = "1"
        self.run_tool("deploy-hw", 24)
        self.assertEqual(self.mutations(), ["unbind", "rmmod"])

    def test_deploy_propagates_insmod_failure(self):
        self.env["INSMOD_RC"] = "17"
        self.run_tool("deploy-hw", 17)
        self.assertEqual(self.mutations(), ["hot-reset", "program-cli", "hot-reset",
                                          "set-hugepages", "insmod"])

    def test_deploy_permits_authorized_selected_reload(self):
        self.bind()
        self.run_tool("deploy-hw", 0)
        self.assertEqual(self.mutations(), ["unbind", "rmmod", "hot-reset", "program-cli",
                                          "hot-reset", "set-hugepages", "insmod"])

    def test_network_args_rejected_before_mutation(self):
        self.image = self.root / "tcp.bit"
        self.image.touch()
        self.env["IMAGE_HINT"] = str(self.image)
        self.reject_both()

    def test_partial_image_rejected_before_mutation(self):
        self.image = self.root / "partial.bin"
        self.image.touch()
        self.run_tool("deploy-hw")
        self.assertEqual(self.mutations(), [])


if __name__ == "__main__":
    unittest.main()
