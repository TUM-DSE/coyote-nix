"""Device-free public safety tests: production shell with virtual filesystem paths."""
import gzip
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile

source = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    bin_dir = root / "bin"
    bin_dir.mkdir()
    log = root / "mutations"
    for name, body in {
        "modinfo": 'case "$2" in name) echo "${MOCK_MODULE:-coyote_driver_versal}";; vermagic) echo "${MOCK_KERNEL:-7.1.9} SMP preempt mod_unload";; esac',
        "uname": 'echo 7.1.9',
        "hostname": 'echo fixture',
        "sudo": 'exec "$@"',
        "insmod": 'echo "insmod $*" >> "$MOCK_LOG"',
        "rmmod": 'echo "rmmod $*" >> "$MOCK_LOG"; : > "$MOCK_MODULES"; rm "$MOCK_DRIVER_LINK"',
    }.items():
        path = bin_dir / name
        path.write_text('#!' + shutil.which('bash') + '\nset -eu\n' + body + '\n')
        path.chmod(0o755)
    scripts = {}
    for name in ("insert-driver", "unload-driver"):
        text = (source / "nix/tools" / (name + ".sh")).read_text()
        for prefix in ("/sys/", "/proc/", "/run/"):
            text = text.replace(prefix, str(root) + prefix)
        path = root / (name + ".sh")
        path.write_text('set -euo pipefail\nsource "$COMMON"\n' + text)
        scripts[name] = path
    modules = root / "proc/modules"
    modules.parent.mkdir()
    modules.write_text("")
    package = root / "package"
    package.mkdir()
    ko = package / "coyote_driver_versal.ko"
    ko.touch()
    kernel = root / "declared-kernel"
    kernel.mkdir()
    (kernel / "bzImage").touch()
    boot = root / "run/booted-system"
    boot.mkdir(parents=True)
    (boot / "kernel").symlink_to(kernel / "bzImage")
    (package / "kernel-store-path").write_text(str(kernel) + "\n")
    (package / "kernel.config").write_bytes(b"CONFIG_SMP=y\n")
    (root / "proc/config.gz").write_bytes(gzip.compress(b"CONFIG_SMP=y\n"))
    drivers = root / "sys/bus/pci/drivers"
    devices = root / "sys/bus/pci/devices"
    selected = drivers / "coyote_driver_versal"
    foreign = drivers / "coyote_driver"
    selected.mkdir(parents=True)
    foreign.mkdir()
    endpoint = devices / "0000:81:00.0"
    endpoint.mkdir(parents=True)
    (endpoint / "driver").symlink_to(selected)
    (selected / endpoint.name).symlink_to(endpoint)
    env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'],
               COMMON=str(source / "nix/tools/coyote-common.sh"), MOCK_LOG=str(log),
               MOCK_MODULES=str(modules), MOCK_DRIVER_LINK=str(endpoint / 'driver'), TARGET_PLATFORM="versal",
               COYOTE_MODULE_NAME="coyote_driver_versal", FPGA_BDF=endpoint.name,
               COYOTE_NIX_INSERT_DRIVER_READY_TIMEOUT_S="0")
    def run(name, args=(), good=True, extra=None):
        log.write_text("")
        result = subprocess.run(['bash', str(scripts[name]), *map(str, args)],
                                env=env | (extra or {}), capture_output=True, text=True)
        assert (result.returncode == 0) == good, result.stdout + result.stderr
        return log.read_text()
    assert 'insmod' in run('insert-driver', [ko])
    assert not run('insert-driver', [ko], False, {'FPGA_BDF': ''})
    assert not run('insert-driver', [ko], False, {'FPGA_BDF': '.'})
    assert not run('insert-driver', [ko], False, {'MOCK_MODULE': 'coyote_driver'})
    assert not run('insert-driver', [ko], False, {'MOCK_KERNEL': '6.9.0-rc7'})
    (package / 'kernel.config').write_bytes(b'CONFIG_SMP=n\n')
    assert not run('insert-driver', [ko], False)
    (package / 'kernel.config').write_bytes(b'CONFIG_SMP=y\n')
    (boot / 'kernel').unlink()
    (boot / 'kernel').symlink_to(root / 'not-booted/bzImage')
    assert not run('insert-driver', [ko], False)
    (boot / 'kernel').unlink()
    (boot / 'kernel').symlink_to(kernel / 'bzImage')
    modules.write_text('coyote_driver_versal 100 0 - Live 0\ncoyote_driver 100 0 - Live 0\n')
    assert not run('unload-driver', good=False, extra={'FPGA_BDF': ''}), 'ambiguous default removal'
    assert not run('unload-driver', good=False, extra={'FPGA_BDF': '.'}), 'invalid target removal'
    (endpoint / 'driver').unlink()
    (endpoint / 'driver').symlink_to(foreign)
    assert not run('insert-driver', [ko], False), 'insert attempted on foreign endpoint'
    assert not run('unload-driver', good=False), 'foreign family changed'
    (endpoint / 'driver').unlink()
    (endpoint / 'driver').symlink_to(selected)
    other = selected / '0000:82:00.0'
    other.symlink_to(endpoint)
    assert not run('unload-driver', good=False), 'other endpoint changed'
    other.unlink()
    assert run('unload-driver') == 'rmmod coyote_driver_versal\n'
    # No module-wide fallback to legacy when the selected family is absent.
    modules.write_text('coyote_driver 100 0 - Live 0\n')
    assert not run('unload-driver')
print('driver deployment: booted-kernel/config, identity, foreign-family and endpoint isolation PASS')
