#!/usr/bin/env python3
"""Exercise the compiled Rust/QML spike with synthetic data; never run provider CLIs."""
import json
import os
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
                with_tray = os.environ.get('PROTOTYPE_TEST_TRAY') == '1'
                evidence = Path(os.environ['PROTOTYPE_EVIDENCE_DIR']) if os.environ.get('PROTOTYPE_EVIDENCE_DIR') else None
                platform = env['QT_QPA_PLATFORM']
                if evidence:
                    evidence.mkdir(parents=True, exist_ok=True)
                argv = [str(BINARY), '--runtime-dir', directory]
                app = subprocess.Popen(argv + ([] if with_tray else ['--no-tray']), env=env, stdout=log, stderr=log)
                try:
                    eventually(lambda: 'Rendered meters: ["75% left","42% left"]' in log_path.read_text())
                    eventually(lambda: capture.exists() and capture.stat().st_size > 1000)
                    self.assertGreater(capture.stat().st_size, 1000)
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

                    for message in [b'{broken}\n', b'{"command":"unsupported"}\n', b'x' * 65536]:
                        with socket.socket(socket.AF_UNIX) as client:
                            client.settimeout(3)
                            client.connect(str(path / 'desktop.sock'))
                            client.sendall(message)
                            self.assertFalse(json.loads(client.makefile('rb').readline())['ok'])
                    self.assertEqual(command('--snapshot')['entries'][0]['windows'][0]['remaining'], 55)
                    command('--quit')
                    self.assertEqual(app.wait(timeout=5), 0)
                    self.assertFalse((path / 'desktop.sock').exists())
                    output = log_path.read_text()
                    for error in ['ReferenceError', 'TypeError', 'QML load failed', 'Capture failed']:
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
                    print(log_path.read_text())


if __name__ == '__main__':
    unittest.main()
