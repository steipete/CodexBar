"""Isolated runtime tests: fake provider CLI, private IPC, offscreen Qt windows."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

APP = Path(os.environ.get('CODEXBAR_LINUX_BINARY', '.local/linux-build/codexbar-linux')).resolve()


class DesktopTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir(mode=0o700)
        self.environment = dict(os.environ, HOME=str(self.root), XDG_CONFIG_HOME=str(self.root / 'config'),
                                XDG_DATA_HOME=str(self.root / 'data'), XDG_STATE_HOME=str(self.root / 'state'), XDG_RUNTIME_DIR=str(self.runtime),
                                QT_QPA_PLATFORM=os.environ.get('CODEXBAR_TEST_PLATFORM', 'offscreen'), QT_QUICK_BACKEND='software', FIXTURE_HOME=str(self.root))
        self.fake = self.root / 'fake-cli'
        self.fake.write_text('''#!/usr/bin/env python3
import datetime,json,os,pathlib,sys,time
root=pathlib.Path(os.environ['FIXTURE_HOME'])
state=json.loads((root/'state.json').read_text()) if (root/'state.json').exists() else {}
args=sys.argv[1:]
provider=args[args.index('--provider')+1] if '--provider' in args else 'codex'
if args[0]=='config':
 print(json.dumps([{'provider':'codex','displayName':'Codex'},{'provider':'claude','displayName':'Claude'}])); sys.exit(0)
with (root/'calls.jsonl').open('a') as log: log.write(json.dumps({'pid':os.getpid(),'args':args})+'\\n')
time.sleep(state.get('delay',0))
if state.get('invalid') or state.get('failProvider')==provider: print('broken'); sys.exit(1)
if args[0]=='cost':
 print(json.dumps([{'provider':'codex','historyCoverageIsEstablished':True,'last30DaysCostUSD':12,
 'daily':[{'date':datetime.date.today().isoformat(),'totalCost':3}], 'totals':{'inputTokens':100}}]))
else:
 print(json.dumps([{'provider':provider,'usage':{'identity':{'accountEmail':'private@example.com'},
 'primary':{'usedPercent':40,'windowMinutes':300,'resetsAt':'2030-01-01T00:00:00Z'}}}]))
''')
        self.fake.chmod(0o755)
        self.log = (self.root / 'desktop.log').open('w+')
        self.process = subprocess.Popen([str(APP), '--background', '--no-tray', '--cli', str(self.fake)],
                                        env=self.environment, stdout=self.log, stderr=self.log)
        self.wait_for(lambda value: len(value.get('entries', [])) == 1)

    def tearDown(self):
        try:
            self.client('--quit', check=False)
            self.process.wait(timeout=4)
        except (subprocess.TimeoutExpired, OSError):
            self.process.kill()
            self.process.wait()
        self.log.flush(); self.log.seek(0)
        log = self.log.read()
        self.log.close()
        self.temporary.cleanup()
        for error in ['ReferenceError', 'TypeError', 'failed to load', 'Cannot assign', 'Unable to assign', 'Binding loop']:
            self.assertNotIn(error, log)

    def client(self, *args, check=True):
        result = subprocess.run([str(APP), *args], env=self.environment, capture_output=True, text=True, timeout=5)
        if check and result.returncode:
            self.fail(result.stderr + result.stdout)
        return json.loads(result.stdout) if result.stdout.strip() else {}

    def wait_for(self, predicate):
        end = time.monotonic() + 12
        last = {}
        while time.monotonic() < end:
            if self.process.poll() is not None:
                self.log.seek(0)
                self.fail(self.log.read())
            last = self.client('--snapshot', check=False)
            if predicate(last):
                return last
            time.sleep(0.05)
        self.log.seek(0)
        self.fail(f'Timed out: {last}\n{self.log.read()}')

    def test_single_instance_and_snapshot_privacy(self):
        first = self.client('--snapshot')
        for _ in range(3):
            self.assertEqual(self.client('--background')['pid'], first['pid'])
        self.assertEqual(first['summary'], 'CX 60%')
        self.assertNotIn('private@example.com', json.dumps(first))
        self.assertNotIn('executable', first)
        socket = self.runtime / 'codexbar-linux' / 'desktop.sock'
        self.assertEqual(socket.stat().st_mode & 0o077, 0)
        calls = (self.root / 'calls.jsonl').read_text().splitlines()
        self.assertEqual(len(calls), 1)

    def test_preferences_validation_and_atomic_save(self):
        self.assertFalse(self.client('--configure', '{"provider":"bad;command"}', check=False)['ok'])
        self.assertTrue(self.client('--configure', '{"provider":"claude","refreshSeconds":900,"showIdentity":true}')['ok'])
        value = self.wait_for(lambda value: value.get('entries') and value['entries'][0]['provider'] == 'claude')
        self.assertNotIn('private@example.com', json.dumps(value))
        settings = self.root / 'config/codexbar/linux.json'
        self.assertEqual(json.loads(settings.read_text())['refreshSeconds'], 900)
        self.assertEqual(settings.stat().st_mode & 0o077, 0)

    def test_invalid_config_is_not_overwritten(self):
        self.client('--quit')
        self.process.wait(timeout=4)
        settings = self.root / 'config/codexbar/linux.json'
        settings.parent.mkdir(parents=True, exist_ok=True)
        settings.write_text('{broken')
        self.process = subprocess.Popen([str(APP), '--background', '--no-tray', '--cli', str(self.fake)],
                                        env=self.environment, stdout=self.log, stderr=self.log)
        self.wait_for(lambda value: bool(value.get('entries')))
        self.assertFalse(self.client('--configure', '{"provider":"claude"}', check=False)['ok'])
        self.assertEqual(settings.read_text(), '{broken')

    def test_old_response_cannot_replace_new_selection(self):
        (self.root / 'state.json').write_text('{"delay":0.5}')
        self.client('--refresh')
        self.wait_for(lambda value: value['busy'])
        self.client('--configure', '{"provider":"claude"}')
        self.assertEqual(self.client('--snapshot')['entries'], [])
        value = self.wait_for(lambda value: value.get('entries') and not value['busy'])
        self.assertEqual(value['entries'][0]['provider'], 'claude')

    def test_failed_refresh_preserves_previous_usage(self):
        (self.root / 'state.json').write_text('{"invalid":true}')
        self.client('--refresh')
        value = self.wait_for(lambda value: bool(value.get('error')))
        self.assertTrue(value['stale'])
        self.assertEqual(value['summary'], 'CX 60%')

    def test_refresh_on_open_is_optional_and_does_not_scan_spending(self):
        calls = self.root / 'calls.jsonl'
        self.client('--usage')
        time.sleep(0.15)
        self.assertEqual(len(calls.read_text().splitlines()), 1)
        self.client('--configure', '{"refreshOnOpen":true}')
        self.wait_for(lambda value: bool(value.get('entries')) and not value['busy'])
        previous = len(calls.read_text().splitlines())
        self.client('--usage')
        end = time.monotonic() + 4
        while len(calls.read_text().splitlines()) == previous and time.monotonic() < end:
            time.sleep(0.05)
        self.assertEqual(len(calls.read_text().splitlines()), previous + 1)
        for line in calls.read_text().splitlines():
            self.assertEqual(json.loads(line)['args'][0], 'usage')

    def test_failed_spending_preserves_previous_scan(self):
        self.client('--spending')
        self.wait_for(lambda value: value.get('costProviders') == 1 and not value['costBusy'])
        (self.root / 'state.json').write_text('{"invalid":true}')
        self.client('--refresh')
        value = self.wait_for(lambda value: bool(value.get('costError')))
        self.assertEqual(value['costProviders'], 1)

    def test_custom_provider_order_and_selection(self):
        self.client('--configure', '{"provider":"custom","providerOrder":["claude","codex"]}')
        value = self.wait_for(lambda value: len(value.get('entries', [])) == 2 and not value['busy'])
        self.assertEqual([row['provider'] for row in value['entries']], ['claude', 'codex'])
        self.client('--settings')
        self.client('--usage')
        calls = [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]
        self.assertEqual([call['args'][call['args'].index('--provider') + 1] for call in calls[-2:]], ['claude', 'codex'])
        self.assertFalse(self.client('--configure', '{"providerOrder":["codex","codex"]}', check=False)['ok'])
        self.assertFalse(self.client('--configure', '{"providerOrder":[]}', check=False)['ok'])

    def test_custom_provider_partial_failure_keeps_other_results(self):
        self.client('--configure', '{"provider":"custom","providerOrder":["claude","codex"]}')
        self.wait_for(lambda value: len(value.get('entries', [])) == 2 and not value['busy'])
        (self.root / 'state.json').write_text('{"failProvider":"claude"}')
        self.client('--refresh')
        value = self.wait_for(lambda value: bool(value.get('error')) and not value['busy'])
        self.assertEqual([row['provider'] for row in value['entries']], ['claude', 'codex'])
        self.assertTrue(value['stale'])

    def test_selection_change_during_custom_batch(self):
        (self.root / 'state.json').write_text('{"delay":0.3}')
        self.client('--configure', '{"provider":"custom","providerOrder":["claude","codex"]}')
        self.wait_for(lambda value: value['busy'])
        self.client('--configure', '{"provider":"gemini"}')
        value = self.wait_for(lambda value: bool(value.get('entries')) and not value['busy'])
        self.assertEqual([row['provider'] for row in value['entries']], ['gemini'])

    def test_autostart_toggle_is_independent_of_preferences(self):
        self.assertFalse(self.client('--autostart', 'status')['enabled'])
        self.assertTrue(self.client('--autostart', 'enable')['enabled'])
        path = self.root / 'config/autostart/com.steipete.CodexBar.desktop'
        self.assertIn('--background', path.read_text())
        self.assertFalse(self.client('--autostart', 'disable')['enabled'])
        self.assertIn('Hidden=true', path.read_text())
        self.assertFalse(self.client('--autostart', 'invalid', check=False)['ok'])

    def test_display_changes_preserve_usage_without_a_provider_query(self):
        count = len((self.root / 'calls.jsonl').read_text().splitlines())
        self.client('--configure', '{"quotaDisplay":"used","resetDisplay":"absolute"}')
        value = self.client('--snapshot')
        self.assertEqual(value['summary'], 'CX 40%')
        self.assertEqual(value['entries'][0]['windows'][0]['displayValue'], 40)
        self.assertEqual(value['entries'][0]['windows'][0]['displaySuffix'], 'used')
        self.assertFalse(value['busy'])
        self.assertEqual(len((self.root / 'calls.jsonl').read_text().splitlines()), count)

    def test_display_settings_validation(self):
        self.assertTrue(self.client('--configure', '{"quotaDisplay":"used","resetDisplay":"both","showPace":false,"trayStyle":"icon","followOmarchyTheme":true}')['ok'])
        self.assertFalse(self.client('--configure', '{"resetDisplay":"nonsense"}', check=False)['ok'])

    def test_windows_and_cost_scan_use_existing_backend(self):
        pid = self.client('--snapshot')['pid']
        self.client('--settings')
        self.client('--spending')
        value = self.wait_for(lambda value: value.get('costProviders') == 1)
        self.assertEqual(value['pid'], pid)
        self.log.flush(); self.log.seek(0)
        log = self.log.read()
        for error in ['ReferenceError', 'TypeError', 'failed to load', 'Cannot assign', 'Unable to assign', 'Binding loop']:
            self.assertNotIn(error, log)


if __name__ == '__main__':
    unittest.main()
