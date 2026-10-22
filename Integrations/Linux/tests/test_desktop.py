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
 usage=state.get('usage',{'identity':{'accountEmail':'private@example.com'},
 'primary':{'usedPercent':40,'windowMinutes':300,'resetsAt':'2030-01-01T00:00:00Z'}})
 answered=state.get('answerAs',{}).get(provider,provider)
 print(json.dumps([{'provider':answered,'usage':usage,'rateWindowLabels':state.get('rateWindowLabels'),'pace':state.get('pace'),'resetCredits':state.get('resetCredits'),'status':state.get('status')}]))
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
        self.assertEqual(first['barEntries'], [{'provider': 'codex', 'tag': 'CX', 'text': '60%'}])
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

    def test_scoped_windows_reach_private_snapshots_without_exporting_identifiers(self):
        usage = {
            'identity': {'accountEmail': 'private@example.invalid'},
            'primary': {'usedPercent': 0, 'windowMinutes': 300, 'isSyntheticPlaceholder': True},
            'secondary': {'usedPercent': 39, 'windowMinutes': 10080},
            'extraRateWindows': [
                {'id': 'private@example.invalid', 'title': 'Model cap (private@example.invalid)',
                 'window': {'usedPercent': 93, 'windowMinutes': 10080}},
                {'id': 'unknown', 'title': 'Unmeasured billing', 'usageKnown': False,
                 'window': {'usedPercent': 100}},
                {'id': 'placeholder', 'title': 'Synthetic extra',
                 'window': {'usedPercent': 0, 'isSyntheticPlaceholder': True}}
            ]
        }
        (self.root / 'state.json').write_text(json.dumps({'usage': usage}))
        self.client('--configure', '{"provider":"claude","showIdentity":true}')
        value = self.wait_for(lambda value: value.get('entries') and value['entries'][0]['provider'] == 'claude'
                              and not value['busy'])
        self.assertNotIn('private@example.invalid', json.dumps(value))
        windows = value['entries'][0]['windows']
        self.assertEqual(len(windows), 2)
        self.assertEqual(windows[0]['key'], 'secondary')
        self.assertRegex(windows[1]['key'], r'^extra:[a-f0-9]{64}$')
        self.assertEqual(windows[1]['label'], 'Model cap [hidden email]')
        self.assertEqual(windows[1]['remaining'], 7)
        self.assertEqual(value['summary'], 'CL 61%')
        self.client('--usage')
        self.client('--refresh')
        refreshed = self.wait_for(lambda value: not value['busy'])
        self.assertEqual(refreshed['entries'][0]['windows'][1]['key'], windows[1]['key'])

    def test_antigravity_pools_reach_snapshots_once_with_representatives_first(self):
        # Core copies the tightest pool of each model family into the positional windows and also
        # lists every pool as a quota-summary extra.
        def pool(used, minutes, reset):
            return {'usedPercent': used, 'windowMinutes': minutes, 'resetsAt': reset}
        gemini_weekly = pool(95, 10080, '2030-01-03T00:00:00Z')
        claude_session = pool(100, 300, '2030-01-01T05:00:00Z')
        usage = {'primary': gemini_weekly, 'secondary': claude_session, 'extraRateWindows': [
            {'id': 'antigravity-quota-summary-' + key, 'title': title, 'usageKnown': True, 'window': window}
            for key, title, window in [
                ('gemini-5h', 'Gemini 5-hour', pool(3, 300, '2030-01-01T03:00:00Z')),
                ('gemini-weekly', 'Gemini weekly', gemini_weekly),
                ('claude-5h', 'Claude/GPT 5-hour', claude_session),
                ('claude-weekly', 'Claude/GPT weekly', pool(0, 10080, '2030-01-07T00:00:00Z'))]]}
        (self.root / 'state.json').write_text(json.dumps({'usage': usage}))
        self.client('--configure', '{"provider":"antigravity"}')
        value = self.wait_for(lambda value: value.get('entries') and value['entries'][0]['provider'] == 'antigravity'
                              and not value['busy'])
        windows = value['entries'][0]['windows']
        self.assertEqual([(window['label'], window['remaining']) for window in windows], [
            ('Gemini weekly', 5), ('Claude/GPT 5-hour', 0), ('Gemini 5-hour', 97), ('Claude/GPT weekly', 100)])
        self.assertEqual(len({window['key'] for window in windows}), 4)
        self.assertEqual(value['summary'], 'antigravity 5%')

    def test_provider_window_labels_reach_private_snapshot(self):
        (self.root / 'state.json').write_text(json.dumps({
            'usage': {'secondary': {'usedPercent': 20}},
            'rateWindowLabels': {'secondary': 'Rate limit'}
        }))
        self.client('--configure', '{"provider":"claude"}')
        value = self.wait_for(lambda value: value.get('entries') and not value['busy']
                              and value['entries'][0]['provider'] == 'claude')
        windows = value['entries'][0]['windows']
        self.assertEqual(len(windows), 1)
        self.assertEqual(windows[0]['key'], 'secondary')
        self.assertEqual(windows[0]['label'], 'Rate limit')
        self.assertEqual(windows[0]['remaining'], 80)

    def test_panel_details_reach_snapshot_without_identity(self):
        (self.root / 'state.json').write_text(json.dumps({
            'usage': {'identity': {'accountEmail': 'private@example.com', 'loginMethod': 'Max'},
                      'primary': {'usedPercent': 25, 'windowMinutes': 300},
                      'providerCost': {'period': 'Extra usage', 'currencyCode': 'Credits', 'balance': 500, 'used': 0},
                      # The CLI owns expiry/status filtering. Raw credit IDs must never reach IPC.
                      'codexResetCredits': {'availableCount': 99, 'credits': [
                          {'id': 'private-credit-id', 'status': 'available', 'expires_at': '2030-01-01T05:00:00Z'},
                          {'id': 'private-credit-id', 'status': 'available', 'expires_at': '2030-01-01T09:00:00+09:00'},
                          {'id': 'private-credit-id', 'status': 'available', 'expires_at': '2020-01-01T00:00:00Z'},
                          {'id': 'private-credit-id', 'status': 'redeemed', 'expires_at': '2030-01-01T00:00:00Z'},
                          {'id': 'private-credit-id', 'status': 'available'}]}},
            'resetCredits': {'available': 3, 'nextExpiresAt': '2030-01-01T00:00:00Z'},
            'pace': {'primary': {'summary': 'On pace', 'expectedUsedPercent': 30}}
        }))
        self.client('--configure', '{"provider":"claude"}')
        value = self.wait_for(lambda value: value.get('entries') and not value['busy']
                              and value['entries'][0].get('plan') == 'Max')
        entry = value['entries'][0]
        self.assertEqual(entry['windows'][0]['paceExpected'], 30)
        self.assertEqual(entry['extraUsage']['balance'], 500)
        self.assertEqual(entry['resetCredits'], {'available': 3, 'nextExpiresAt': '2030-01-01T00:00:00Z'})
        self.assertNotIn('private-credit-id', json.dumps(value))
        self.assertEqual(value['spending'], [])
        self.assertNotIn('private@example.com', json.dumps(value))
        self.client('--snapshot', '--with-spending')
        value = self.wait_for(lambda value: bool(value.get('spending')))
        self.assertEqual(value['spending'][0]['month'], 12)

    def test_snapshot_redacts_provider_labels_even_when_identity_is_visible(self):
        (self.root / 'state.json').write_text(json.dumps({
            'usage': {'identity': {'loginMethod': 'Max private@example.com'},
                      'primary': {'usedPercent': 25, 'windowMinutes': 300}},
            'status': {'description': 'Incident for private@example.com', 'indicator': 'minor'}
        }))
        self.client('--configure', '{"provider":"claude","showIdentity":true}')
        value = self.wait_for(lambda value: value.get('entries') and not value['busy']
                              and value['entries'][0].get('statusLevel') == 'minor')
        self.assertEqual(value['entries'][0]['plan'], 'Max [hidden email]')
        self.assertEqual(value['entries'][0]['status'], 'Incident for [hidden email]')
        self.assertNotIn('private@example.com', json.dumps(value))

    def test_spending_snapshot_recovers_after_failed_scan(self):
        state = self.root / 'state.json'
        state.write_text('{"failProvider":"both"}')
        self.client('--snapshot', '--with-spending')
        self.wait_for(lambda value: bool(value.get('costError')) and not value['costBusy'])
        state.unlink()
        time.sleep(5.2)
        self.client('--snapshot', '--with-spending')
        value = self.wait_for(lambda value: bool(value.get('spending')) and not value['costBusy'])
        self.assertEqual(value['costError'], '')
        self.assertEqual(value['spending'][0]['month'], 12)

    def test_bar_detail_caps_and_pace_are_independent_preferences(self):
        usage = {'primary': {'usedPercent': 63, 'windowMinutes': 300, 'resetsAt': '2030-01-01T05:00:00Z'},
                 'secondary': {'usedPercent': 39, 'windowMinutes': 10080, 'resetsAt': '2030-01-03T00:00:00Z'},
                 'extraRateWindows': [{'id': 'claude-weekly-scoped-fable', 'title': 'Fable only',
                                       'window': {'usedPercent': 100, 'windowMinutes': 10080}}]}
        (self.root / 'state.json').write_text(json.dumps({
            'usage': usage, 'pace': {'secondary': {'deltaPercent': 14, 'expectedUsedPercent': 25}}}))
        self.client('--refresh')
        value = self.wait_for(lambda value: value.get('entries') and not value['busy'])
        # Default: the single leading percentage this adapter has always drawn.
        self.assertEqual([entry['text'] for entry in value['barEntries']], ['37%'])
        self.assertTrue(self.client('--configure', '{"showBarDetail":true}')['ok'])
        value = self.wait_for(lambda value: value['barEntries'][0]['text'] != '37%')
        self.assertEqual([entry['text'] for entry in value['barEntries']], ['5H 37% · 7D 61% · +14%'])
        self.assertTrue(self.client('--configure', '{"showScopedCaps":true}')['ok'])
        value = self.wait_for(lambda value: 'Fable' in value['barEntries'][0]['text'])
        self.assertEqual([entry['text'] for entry in value['barEntries']], ['5H 37% · 7D 61% · Fable 0% · +14%'])
        self.assertEqual(value['entries'][0]['windows'][1]['paceExpected'], 25)
        self.assertTrue(self.client('--configure', '{"showPace":false}')['ok'])
        self.assertEqual(self.client('--snapshot')['barEntries'][0]['text'], '5H 37% · 7D 61% · Fable 0%')
        self.assertTrue(self.client('--configure', '{"showBarDetail":false}')['ok'])
        self.assertEqual(self.client('--snapshot')['barEntries'][0]['text'], '37% · Fable 0%')
        # The tray tooltip keeps its own compact form.
        self.assertEqual(value['summary'], 'CX 37%')

    def test_bar_provider_limit_validates_and_only_changes_display(self):
        providers = ['codex', 'claude', 'acme']
        self.assertTrue(self.client('--configure', json.dumps({
            'provider': 'custom', 'providerOrder': providers}))['ok'])
        value = self.wait_for(lambda value: len(value.get('entries', [])) == 3 and not value['busy'])
        self.assertEqual([row['provider'] for row in value['barEntries']], providers[:2])
        self.assertEqual(value['summary'], 'CX 60%  ·  CL 60%  +1')
        calls = (self.root / 'calls.jsonl').read_text()
        for limit in [1, 0, 80, 2]:
            self.assertTrue(self.client('--configure', json.dumps({'barProviders': limit}))['ok'])
            value = self.client('--snapshot')
            self.assertEqual([row['provider'] for row in value['barEntries']], providers[:limit or None])
            self.assertEqual([row['provider'] for row in value['entries']], providers)
            self.assertEqual(value['summary'], 'CX 60%  ·  CL 60%  +1')
        self.assertEqual((self.root / 'calls.jsonl').read_text(), calls)
        settings = self.root / 'config/codexbar/linux.json'
        saved = settings.read_bytes()
        for limit in [-1, 81, 'invalid', None]:
            self.assertFalse(self.client('--configure', json.dumps({'barProviders': limit}), check=False)['ok'])
            self.assertEqual(settings.read_bytes(), saved)
        self.client('--refresh')
        self.wait_for(lambda value: not value['busy'])
        calls = [json.loads(line)['args'] for line in (self.root / 'calls.jsonl').read_text().splitlines()]
        polled = [args[args.index('--provider') + 1] for args in calls if args[0] == 'usage']
        self.assertEqual(polled[-3:], providers)

    def test_settings_from_before_the_bar_preferences_survive_an_upgrade(self):
        self.client('--quit')
        self.process.wait(timeout=4)
        settings = self.root / 'config/codexbar/linux.json'
        settings.parent.mkdir(parents=True, exist_ok=True)
        # Written by a release without showBarDetail, showScopedCaps or barProviders.
        settings.write_text(json.dumps({'provider': 'custom', 'providerOrder': ['claude', 'codex'],
                                        'quotaDisplay': 'used', 'showPace': False, 'refreshSeconds': 600}))
        self.process = subprocess.Popen([str(APP), '--background', '--no-tray', '--cli', str(self.fake)],
                                        env=self.environment, stdout=self.log, stderr=self.log)
        value = self.wait_for(lambda value: len(value.get('entries', [])) == 2 and not value['busy'])
        self.assertEqual([entry['provider'] for entry in value['entries']], ['claude', 'codex'])
        self.assertEqual(value['quotaDisplay'], 'used')
        self.assertEqual([entry['text'] for entry in value['barEntries']], ['40%', '40%'])
        self.assertTrue(self.client('--configure', '{"notifyThreshold":20}')['ok'])
        saved = json.loads(settings.read_text())
        self.assertEqual({key: saved[key] for key in ['provider', 'providerOrder', 'quotaDisplay', 'showPace', 'refreshSeconds']},
                         {'provider': 'custom', 'providerOrder': ['claude', 'codex'], 'quotaDisplay': 'used',
                          'showPace': False, 'refreshSeconds': 600})
        self.assertEqual((saved['showBarDetail'], saved['showScopedCaps'], saved['barProviders']), (False, False, 2))

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

    def test_quick_view_is_opt_in_and_never_scans_cost_on_open(self):
        calls = self.root / 'calls.jsonl'
        self.client('--configure', '{}')
        settings = self.root / 'config/codexbar/linux.json'
        self.assertFalse(json.loads(settings.read_text())['compactQuickView'])
        for enabled in [False, True]:
            self.client('--configure', json.dumps({'compactQuickView': enabled}))
            self.assertEqual(json.loads(settings.read_text())['compactQuickView'], enabled)
            for command in ['--usage', '--quick-view']:
                self.client(command)
                snapshot = self.client('--snapshot')
                self.assertFalse(snapshot['costBusy'])
                self.assertEqual(snapshot['costProviders'], 0)
        self.assertEqual([json.loads(line)['args'][0] for line in calls.read_text().splitlines()], ['usage'])
        self.client('--configure', '{"refreshOnOpen":true}')
        self.client('--quick-view')
        self.wait_for(lambda value: not value['busy'] and len(calls.read_text().splitlines()) >= 2)
        self.assertEqual([json.loads(line)['args'][0] for line in calls.read_text().splitlines()],
                         ['usage', 'usage'])
        self.client('--spending')
        self.wait_for(lambda value: value['costProviders'] == 1 and not value['costBusy'])
        self.client('--quick-view')
        self.assertEqual([json.loads(line)['args'][0] for line in calls.read_text().splitlines()].count('cost'), 1)

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

    def test_custom_provider_ignores_usage_answered_for_another_provider(self):
        # An older CLI answers an unrecognised ID with its enabled providers instead of failing.
        (self.root / 'state.json').write_text('{"answerAs":{"alibabatokenplan":"codex"}}')
        self.client('--configure', '{"provider":"custom","providerOrder":["codex","alibabatokenplan"]}')
        value = self.wait_for(lambda value: len(value.get('entries', [])) == 2 and not value['busy'])
        self.assertEqual([row['provider'] for row in value['entries']], ['codex', 'alibabatokenplan'])
        self.assertEqual(value['entries'][1]['windows'], [])
        self.assertEqual(value['entries'][1]['error'], 'Usage unavailable')

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
        self.assertEqual(value['barEntries'], [{'provider': 'codex', 'tag': 'CX', 'text': '40%'}])
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
