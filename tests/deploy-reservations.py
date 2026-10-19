"""Isolated deploy-hw reservation command-boundary regressions. No device access."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1)).resolve()

class Reservations(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.events = self.root / 'events'
        self.state = self.root / 'state'
        self.state.write_text('{}')
        self.image = self.root / 'image.pdi'
        self.image.touch()
        (self.root / 'driver.ko').touch()
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        FIXTURE=str(self.root), FPGA_BDF='0000:81:00.0')
        self.script('sudo', 'if [ "$1" = -v ]; then exit 0; fi; if [ "$1" = -n ]; then shift; fi; exec "$@"')
        self.script('uuidgen', 'echo 12345678-1234-1234-1234-123456789abc')
        for command in ('unload-driver', 'hot-reset', 'program-cli', 'set-hugepages', 'insert-driver'):
            self.script(command, f'echo {command} >> "$FIXTURE/events"; if [ "${{SIGNAL_STEP:-}}" = {command} ]; then kill -TERM "$DEPLOY_PID"; fi; if [ "${{FAIL_STEP:-}}" = {command} ]; then exit 23; fi')
        self.script('fpgahog', '''exec "''' + sys.executable + '''" - "$@" <<'PY'
import os, sys, json
from pathlib import Path
root=Path(os.environ['FIXTURE']); path=root/'state'
a=sys.argv[1:]; action=a[1]; state=json.loads(path.read_text())
with (root/'events').open('a') as f: f.write('hog '+action+'\\n')
if action in ('acquire','verify'):
    assert a[a.index('--bdf')+1]=='0000:81:00.0'
if action=='acquire':
    expiry=a[a.index('--expiry')+1]
    if expiry not in ('never','4h'):
        print('invalid expiry',file=sys.stderr); sys.exit(2)
    if state.get('owner')=='alice':
        print('FPGA reserved by alice',file=sys.stderr); sys.exit(1)
    if not state:
        state={'owner':'me','token':a[a.index('--token')+1], 'expiry':expiry}
    print('Release: sudo fpgahog reservation release --token '+state.get('token','existing'))
elif action=='release':
    if os.environ.get('CLEANUP_FAIL'): sys.exit(9)
    if state.get('token')==a[a.index('--token')+1]: state={}
elif action=='verify':
    if os.environ.get('VERIFY_FAIL'): sys.exit(8)
    assert state.get('owner')=='me'
else: raise AssertionError(action)
path.write_text(json.dumps(state))
PY''')
        preamble = '''export DEPLOY_PID=$$
resolve_project_root() { echo "$FIXTURE"; }
resolve_target_platform() { echo versal; }
resolve_driver_package_name() { echo fixture; }
resolve_default_driver_ko_from_package() { echo "$FIXTURE/driver.ko"; }
coyote_driver_preflight() { :; }
coyote_unload_preflight() { :; }
'''
        self.script('deploy', preamble + (ROOT/'nix/tools/deploy-hw.sh').read_text())

    def script(self, name, body):
        path=self.bin/name
        path.write_text(f'#!{shutil.which("bash")}\nset -euo pipefail\n'+body+'\n')
        path.chmod(0o755)

    def run_deploy(self, *args):
        return subprocess.run([str(self.bin/'deploy'), *args, str(self.image)], env=self.env, text=True, capture_output=True, timeout=15)

    def log(self):
        return self.events.read_text().splitlines() if self.events.exists() else []

    def test_no_hog_unchanged(self):
        r=self.run_deploy(); self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse(any(x.startswith('hog') for x in self.log()))

    def test_success_keeps_indefinite_claim_and_prints_release(self):
        r=self.run_deploy('--hog'); self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads(self.state.read_text())['expiry'],'never')
        self.assertEqual(self.log()[0],'hog acquire')
        self.assertEqual(self.log()[-1],'hog verify')
        self.assertIn('Release:',r.stdout)

    def test_explicit_expiry(self):
        r=self.run_deploy('--hog=4h'); self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads(self.state.read_text())['expiry'],'4h')

    def test_conflict_prints_owner_before_hardware(self):
        self.state.write_text('{"owner":"alice"}')
        r=self.run_deploy('--hog'); self.assertNotEqual(r.returncode,0)
        self.assertIn('alice',r.stderr)
        self.assertTrue(all(x.startswith('hog') for x in self.log()))
        self.assertEqual(json.loads(self.state.read_text())['owner'],'alice')

    def test_each_deployment_failure_releases_new_claim(self):
        for step in ('unload-driver','hot-reset','program-cli','set-hugepages','insert-driver'):
            with self.subTest(step=step):
                self.env['FAIL_STEP']=step
                r=self.run_deploy('--hog'); self.assertEqual(r.returncode,23,r.stderr)
                self.assertEqual(json.loads(self.state.read_text()),{})

    def test_termination_releases_new_claim(self):
        self.env['SIGNAL_STEP']='program-cli'
        r=self.run_deploy('--hog'); self.assertEqual(r.returncode,143,r.stderr)
        self.assertEqual(json.loads(self.state.read_text()),{})

    def test_failed_enforcement_verification_rolls_back(self):
        self.env['VERIFY_FAIL']='1'
        r=self.run_deploy('--hog'); self.assertEqual(r.returncode,8,r.stderr)
        self.assertEqual(json.loads(self.state.read_text()),{})

    def test_failure_preserves_existing_own_reservation(self):
        self.state.write_text('{"owner":"me","token":"existing"}')
        self.env['FAIL_STEP']='program-cli'
        r=self.run_deploy('--hog'); self.assertEqual(r.returncode,23,r.stderr)
        self.assertEqual(json.loads(self.state.read_text())['token'],'existing')

    def test_cleanup_failure_reports_recovery_and_preserves_error(self):
        self.env.update(FAIL_STEP='program-cli',CLEANUP_FAIL='1')
        r=self.run_deploy('--hog'); self.assertEqual(r.returncode,23,r.stderr)
        self.assertIn('cleanup failed',r.stderr)
        self.assertIn('reservation release --token',r.stderr)

    def test_invalid_expiry_never_touches_hardware(self):
        for arg in ('--hog=','--hog=bogus'):
            r=self.run_deploy(arg); self.assertNotEqual(r.returncode,0)
            self.assertTrue(all(x.startswith('hog') for x in self.log()))
            self.assertEqual(json.loads(self.state.read_text()),{})

if __name__=='__main__': unittest.main()
