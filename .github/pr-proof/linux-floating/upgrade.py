"""Run a real v0.84.0 -> feature-build preferences upgrade against a fake CLI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def run_upgrade(legacy, head, env, output):
    legacy, head = str(Path(legacy).resolve()), str(Path(head).resolve())
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='codexbar-settings-upgrade-') as directory:
        home = Path(directory)
        (home / 'runtime').mkdir(mode=0o700)
        env = dict(env, HOME=str(home), XDG_CONFIG_HOME=str(home / 'config'),
                   XDG_DATA_HOME=str(home / 'data'), XDG_CACHE_HOME=str(home / 'cache'),
                   XDG_STATE_HOME=str(home / 'state'), XDG_RUNTIME_DIR=str(home / 'runtime'))
        env.pop('PYTHONHOME', None)
        env.pop('PYTHONPATH', None)
        cli = home / 'fixture-cli'
        cli.write_text('''#!/usr/bin/python3
import json,sys
if sys.argv[1]=='config': print(json.dumps([{'provider':p,'displayName':p.title()} for p in ['codex','claude']]))
elif sys.argv[1]=='usage':
 provider=sys.argv[sys.argv.index('--provider')+1]
 print(json.dumps([{'provider':provider,'usage':{'primary':{'usedPercent':40,'windowMinutes':300}}}]))
else: raise SystemExit('Unexpected fixture command')
''')
        cli.chmod(0o755)
        settings = home / 'config/codexbar/linux.json'
        chosen = {'provider': 'custom', 'providerOrder': ['claude', 'codex'],
                  'refreshSeconds': 900, 'notifyThreshold': 17, 'quotaDisplay': 'used',
                  'resetDisplay': 'both', 'compactQuickView': True, 'showCosts': False,
                  'showTray': False, 'showStatus': False, 'showIdentity': False,
                  'showPace': False, 'showBarDetail': True, 'warningColors': False}
        results = {'legacyTag': 'v0.84.0',
                   'legacyCommit': '5bebf9a05e68059eae11d5031c7239f1aa1d49ef',
                   'legacyBinarySHA256': hashlib.sha256(Path(legacy).read_bytes()).hexdigest(),
                   'headBinarySHA256': hashlib.sha256(Path(head).read_bytes()).hexdigest(),
                   'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                   'fixture': 'Same private HOME/XDG paths and fake CLI for both real executables'}

        for stage, binary in [('legacy', legacy), ('head', head)]:
            with (home / (stage + '.log')).open('w+') as log:
                app = subprocess.Popen([binary, '--background', '--no-tray', '--cli', str(cli)],
                                       env=env, stdout=log, stderr=log)
                def client(*arguments):
                    result = subprocess.run([binary, *arguments], env=env, capture_output=True,
                                            text=True, check=True, timeout=10)
                    return json.loads(result.stdout) if result.stdout.strip() else {}
                def ready(expected):
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        if app.poll() is not None:
                            log.flush(); log.seek(0)
                            raise RuntimeError(log.read())
                        try:
                            value = client('--snapshot')
                            if not value['busy'] and len(value['entries']) == expected:
                                return value
                        except subprocess.CalledProcessError:
                            pass
                        time.sleep(0.1)
                    raise AssertionError('Upgrade snapshot did not become ready')
                try:
                    if stage == 'legacy':
                        ready(1)
                        assert client('--configure', json.dumps(chosen))['ok']
                        results['legacySnapshot'] = ready(2)
                        before_bytes = settings.read_bytes()
                        before = json.loads(before_bytes)
                        assert 'showFloating' not in before, 'Old program must generate the old schema'
                        assert all(before[key] == value for key, value in chosen.items())
                    else:
                        results['headSnapshot'] = ready(2)
                        assert settings.read_bytes() == before_bytes, 'Startup must not rewrite old preferences'
                        if env.get('QT_QPA_PLATFORM') == 'xcb':
                            tree = subprocess.check_output(['/usr/bin/xwininfo', '-root', '-tree'],
                                                           env=env, text=True)
                            for wid in re.findall(r'(0x[0-9a-f]+) "CodexBar[^\n"]*Floating Gauge[^\n"]*"', tree):
                                info = subprocess.check_output(['/usr/bin/xwininfo', '-id', wid], env=env, text=True)
                                assert 'Map State: IsViewable' not in info, 'Upgrade must not show the gauge'
                            results['noVisibleGaugeVerifiedOnX11'] = True
                        assert client('--configure', '{}')['ok'], 'New settings owner must accept the old data'
                        after = json.loads(settings.read_text())
                        assert all(after[key] == value for key, value in before.items()), 'Existing values changed'
                        assert after['showFloating'] is False
                        assert after['floatingCompact'] is True
                        results['oldPreferencesUnchangedOnStartup'] = True
                        results['allOldPreferencesRetainedAfterSave'] = True
                        results['gaugeDisabledAfterUpgrade'] = True
                        results['oldPreferences'] = dict(before, executable='<isolated-fixture-cli>')
                        results['upgradedPreferences'] = dict(after, executable='<isolated-fixture-cli>')
                        results['newPreferenceKeys'] = sorted(after.keys() - before.keys())
                finally:
                    if app.poll() is None:
                        try: client('--quit'); app.wait(timeout=5)
                        except Exception: app.kill(); app.wait()
        for snapshot in [results['legacySnapshot'], results['headSnapshot']]:
            snapshot.pop('pid', None)
        results['result'] = 'passed'
        (output / 'upgrade-results.json').write_text(json.dumps(results, indent=2) + '\n')
        return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--legacy-binary', required=True)
    parser.add_argument('--head-binary', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    env = dict(os.environ, QT_QPA_PLATFORM=os.environ.get('QT_QPA_PLATFORM', 'offscreen'),
               QT_QUICK_BACKEND='software', PATH='/usr/bin:/bin')
    print(json.dumps(run_upgrade(args.legacy_binary, args.head_binary, env, args.output), indent=2))
