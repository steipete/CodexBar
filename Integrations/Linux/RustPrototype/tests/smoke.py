#!/usr/bin/env python3
"""Exercise the compiled Rust/QML spike with synthetic data; never run provider CLIs."""
import json
import os
import re
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'target/debug/codexbar-rust-prototype'


def eventually(check, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.05)
    raise AssertionError('Timed out waiting for prototype')


class DesktopSmoke(unittest.TestCase):
    def test_background_theme_and_separate_settings(self):
        with tempfile.TemporaryDirectory(prefix='cbrust-background-') as directory:
            path = Path(directory)
            theme = path / 'state/omarchy/current/theme/colors.toml'
            theme.parent.mkdir(parents=True)
            theme.write_text('background = "#1a1b26"\nforeground = "#a9b1d6"\naccent = "#7aa2f7"\n')
            capture = path / 'window.png'
            output = path / 'app.log'
            platform = os.environ.get('PROTOTYPE_QPA', 'offscreen')
            env = {**os.environ, 'XDG_STATE_HOME': str(path / 'state'),
                   'QT_QPA_PLATFORM': platform, 'QT_QUICK_BACKEND': 'software',
                   'QT_QUICK_CONTROLS_STYLE': 'Fusion', 'QT_QPA_PLATFORMTHEME': '',
                   'CODEXBAR_RUST_CAPTURE': str(capture), 'QT_FORCE_STDERR_LOGGING': '1'}
            argv = [str(BINARY), '--runtime-dir', directory, '--config', str(path / 'settings.json')]
            with output.open('w') as log:
                app = subprocess.Popen(argv + ['--background', '--no-tray'], env=env, stdout=log, stderr=log)
                try:
                    eventually(lambda: 'Rust prototype QML loaded' in output.read_text())
                    def command(name):
                        return json.loads(subprocess.check_output(argv + [name], env=env, timeout=4))
                    self.assertEqual(command('--snapshot')['window'], 'background')
                    self.assertFalse(capture.exists(), 'Background startup displayed the dashboard')
                    command('--settings')
                    settings_capture = Path(str(capture) + '.settings.png')
                    eventually(lambda: settings_capture.exists() and settings_capture.stat().st_size > 1000)
                    self.assertIn('Captured settings palette: #1a1b26', output.read_text())
                    self.assertFalse(capture.exists(), 'Opening Settings also displayed the dashboard')
                    command('--quit')
                    self.assertEqual(app.wait(timeout=5), 0)
                    for error in ['ReferenceError', 'TypeError', 'Binding loop', 'Capture failed']:
                        self.assertNotIn(error, output.read_text())
                    if os.environ.get('PROTOTYPE_EVIDENCE_DIR'):
                        evidence = Path(os.environ['PROTOTYPE_EVIDENCE_DIR'])
                        evidence.mkdir(parents=True, exist_ok=True)
                        (evidence / f'{platform}-themed-settings.png').write_bytes(settings_capture.read_bytes())
                        (evidence / f'{platform}-background.log').write_text(output.read_text())
                finally:
                    if app.poll() is None:
                        app.terminate()
                        app.wait(timeout=5)
                    print(output.read_text())

    def test_window_ipc_and_optional_tray(self):
        with tempfile.TemporaryDirectory(prefix='cbrust-test-') as directory:
            path = Path(directory)
            capture = path / 'window.png'
            log_path = path / 'app.log'
            with log_path.open('w') as log:
                env = {**os.environ, 'QT_QPA_PLATFORM': os.environ.get('PROTOTYPE_QPA', 'offscreen'),
                       'QT_QUICK_BACKEND': 'software', 'QT_QUICK_CONTROLS_STYLE': 'Fusion',
                       'QT_QPA_PLATFORMTHEME': '', 'QT_ACCESSIBILITY': '0', 'NO_AT_BRIDGE': '1',
                       'QT_FORCE_STDERR_LOGGING': '1', 'CODEXBAR_RUST_CAPTURE': str(capture)}
                env['XDG_STATE_HOME'] = str(path / 'state')
                with_tray = os.environ.get('PROTOTYPE_TEST_TRAY') == '1'
                evidence = Path(os.environ['PROTOTYPE_EVIDENCE_DIR']) if os.environ.get('PROTOTYPE_EVIDENCE_DIR') else None
                platform = env['QT_QPA_PLATFORM']
                if evidence:
                    evidence.mkdir(parents=True, exist_ok=True)
                config = path / 'settings.json'
                argv = [str(BINARY), '--runtime-dir', directory, '--config', str(config)]
                app = subprocess.Popen(argv + ([] if with_tray else ['--no-tray']), env=env, stdout=log, stderr=log)
                try:
                    eventually(lambda: 'Rendered meters: ["75% left","42% left"]' in log_path.read_text())
                    eventually(lambda: capture.exists() and capture.stat().st_size > 1000)
                    self.assertGreater(capture.stat().st_size, 1000)
                    geometry = json.loads(re.search(r'Rendered plan: (\{[^\n]+\})', log_path.read_text()).group(1))
                    self.assertGreater(geometry['width'], 100, 'Plan label collapsed into a narrow column')
                    self.assertLess(geometry['height'], 80, 'Plan label wrapped into too many lines')
                    self.assertEqual(app.poll(), None)

                    def command(name):
                        # IPC clients must work even without a usable GUI platform.
                        result = subprocess.run(argv + [name], env={**env, 'QT_QPA_PLATFORM': 'invalid-test-platform'},
                                                capture_output=True, text=True, timeout=4, check=True)
                        return json.loads(result.stdout)

                    initial = command('--snapshot')
                    self.assertEqual(initial['entries'][0]['windows'][0]['remaining'], 75)
                    self.assertTrue(initial['prototype'])
                    duplicate = subprocess.run(argv + ['--no-tray'], env=env, capture_output=True, text=True, timeout=4)
                    self.assertNotEqual(duplicate.returncode, 0)
                    self.assertIn('already running', duplicate.stderr)

                    bus_name = None
                    if with_tray:
                        def tray_ready():
                            nonlocal bus_name
                            names = json.loads(subprocess.check_output(['busctl', '--user', '--json=short', 'list']))
                            bus_name = next((item['name'] for item in names if item['name'].startswith(f'org.kde.StatusNotifierItem-{app.pid}-')), None)
                            return bus_name is not None
                        eventually(tray_ready)
                        def tray_property(name):
                            return json.loads(subprocess.check_output(['busctl', '--user', '--json=short', 'get-property',
                                bus_name, '/StatusNotifierItem', 'org.kde.StatusNotifierItem', name]))
                        before_icon = tray_property('IconPixmap')
                        self.assertIn('75%', str(tray_property('ToolTip')))

                    refreshed = command('--refresh')
                    expected_remaining = 55
                    self.assertEqual(refreshed['entries'][0]['windows'][0]['remaining'], 55)
                    eventually(lambda: 'Rendered meters: ["55% left","42% left"]' in log_path.read_text())
                    if with_tray:
                        eventually(lambda: tray_property('IconPixmap') != before_icon)
                        self.assertIn('55%', str(tray_property('ToolTip')))
                        if evidence:
                            (evidence / f'{platform}-tray.json').write_text(json.dumps({
                                'before': before_icon, 'after': tray_property('IconPixmap'),
                                'tooltip': tray_property('ToolTip')}))
                            if platform == 'xcb':
                                subprocess.run(['scrot', '--overwrite', '--delay', '1',
                                    str(evidence / 'x11-desktop.png')], check=True, timeout=5)
                        subprocess.run(['busctl', '--user', 'call', bus_name, '/StatusNotifierItem',
                            'org.kde.StatusNotifierItem', 'Activate', 'ii', '0', '0'], check=True)
                        self.assertGreater(command('--snapshot')['windowSerial'], initial['windowSerial'])
                        expected_remaining = 35
                        eventually(lambda: command('--snapshot')['entries'][0]['windows'][0]['remaining'] == expected_remaining)
                        eventually(lambda: 'Rust tray panel opened' in log_path.read_text())
                        eventually(lambda: Path(str(capture) + '.tray.png').exists())

                    command('--settings')
                    eventually(lambda: 'Rust settings opened' in log_path.read_text())
                    eventually(lambda: Path(str(capture) + '.settings.png').exists())

                    for message in [b'{broken}\n', b'{"command":"unsupported"}\n', b'x' * 65536]:
                        with socket.socket(socket.AF_UNIX) as client:
                            client.settimeout(3)
                            client.connect(str(path / 'desktop.sock'))
                            client.sendall(message)
                            self.assertFalse(json.loads(client.makefile('rb').readline())['ok'])
                    self.assertEqual(command('--snapshot')['entries'][0]['windows'][0]['remaining'], expected_remaining)
                    def configure(changes):
                        with socket.socket(socket.AF_UNIX) as client:
                            client.settimeout(3)
                            client.connect(str(path / 'desktop.sock'))
                            client.sendall(json.dumps({'command': 'configure', 'settings': changes}).encode() + b'\n')
                            return json.loads(client.makefile('rb').readline())
                    self.assertTrue(configure({'quotaDisplay': 'used', 'notifyThreshold': 40})['ok'])
                    saved = config.read_bytes()
                    rejected = configure({'quotaDisplay': 'remaining', 'notifyThreshold': 120})
                    self.assertFalse(rejected['ok'])
                    self.assertEqual(rejected['settings']['quotaDisplay'], 'used')
                    window = rejected['entries'][0]['windows'][0]
                    self.assertEqual(window['displayValue'], 100 - expected_remaining)
                    self.assertEqual(window['displaySuffix'], 'used')
                    self.assertEqual(window['warning'], expected_remaining <= 40)
                    self.assertEqual(config.read_bytes(), saved)
                    self.assertEqual(config.stat().st_mode & 0o777, 0o600)
                    if with_tray:
                        eventually(lambda: 'used' in str(tray_property('ToolTip')))
                    command('--quit')
                    self.assertEqual(app.wait(timeout=5), 0)
                    self.assertFalse((path / 'desktop.sock').exists())
                    # Preferences survive a fresh process, without reading real user settings.
                    app = subprocess.Popen(argv + ['--no-tray'], env=env, stdout=log, stderr=log)
                    eventually(lambda: (path / 'desktop.sock').exists())
                    eventually(lambda: command('--snapshot')['settings']['quotaDisplay'] == 'used')
                    command('--quit')
                    self.assertEqual(app.wait(timeout=5), 0)
                    output = log_path.read_text()
                    for error in ['ReferenceError', 'TypeError', 'QML load failed', 'Capture failed', 'Binding loop']:
                        self.assertNotIn(error, output)
                finally:
                    if app.poll() is None:
                        app.terminate()
                        app.wait(timeout=5)
                    if os.environ.get('PROTOTYPE_CAPTURE_OUTPUT') and capture.exists():
                        Path(os.environ['PROTOTYPE_CAPTURE_OUTPUT']).write_bytes(capture.read_bytes())
                    if evidence:
                        (evidence / f'{platform}-app.log').write_text(log_path.read_text())
                        if capture.exists():
                            (evidence / f'{platform}-qml.png').write_bytes(capture.read_bytes())
                        for name in ['tray', 'settings']:
                            source = Path(str(capture) + f'.{name}.png')
                            if source.exists():
                                (evidence / f'{platform}-{name}.png').write_bytes(source.read_bytes())
                    print(log_path.read_text())


if __name__ == '__main__':
    unittest.main()
