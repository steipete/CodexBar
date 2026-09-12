import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class InstallTests(unittest.TestCase):
    def test_migration_and_reinstall_preserve_preferences_and_layout(self):
        with tempfile.TemporaryDirectory(prefix='codexbar install ') as temporary:
            home = Path(temporary)
            config = home / 'config'
            shell = config / 'omarchy/shell.json'
            shell.parent.mkdir(parents=True)
            shell.write_text(json.dumps({'bar': {'layout': {'right': [
                {'id': 'steipete.codexbar', 'provider': 'claude', 'refreshSeconds': 900, 'allAccounts': True},
                {'id': 'omarchy.clock'}]}}, 'idle': {'lock': 123}}))
            script = Path(__file__).with_name('install.py')
            environment = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(config), XDG_DATA_HOME=str(home/'data'))
            for _ in range(2):
                subprocess.run(['python3', str(script), '--executable', '/usr/bin/true',
                                '--desktop-binary', '/usr/bin/true'], env=environment, check=True, capture_output=True)
            result = json.loads(shell.read_text())
            self.assertEqual(result['idle'], {'lock': 123})
            self.assertEqual([e['id'] for e in result['bar']['layout']['right']], ['steipete.codexbar', 'omarchy.clock'])
            entry = result['bar']['layout']['right'][0]
            self.assertEqual(set(entry), {'id', 'desktopExecutable'})
            settings = json.loads((config/'codexbar/linux.json').read_text())
            self.assertEqual(settings['provider'], 'claude')
            self.assertEqual(settings['refreshSeconds'], 900)
            self.assertTrue(settings['allAccounts'])
            self.assertFalse(settings['showTray'])
            self.assertEqual(len(list((shell.parent / 'plugins').glob('*/manifest.json'))), 1)
            self.assertEqual(len(list((shell.parent / 'backups').iterdir())), 1)
            self.assertEqual((config/'codexbar/linux.json').stat().st_mode & 0o077, 0)
            launcher = (home/'data/applications/com.steipete.CodexBar.desktop').read_text()
            self.assertIn(f'Exec="{home}/.local/bin/codexbar-linux" --settings', launcher)
            self.assertTrue((config/'autostart/com.steipete.CodexBar.desktop').exists())

    def test_standalone_install_does_not_require_omarchy(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            environment = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home/'config'), XDG_DATA_HOME=str(home/'data'))
            script = Path(__file__).resolve().parents[1] / 'Linux/install.py'
            subprocess.run(['python3', str(script), '--binary', '/usr/bin/true', '--cli', '/usr/bin/true', '--no-autostart'],
                           env=environment, check=True, capture_output=True)
            self.assertFalse((home/'config/omarchy').exists())
            self.assertIn('Hidden=true', (home/'config/autostart/com.steipete.CodexBar.desktop').read_text())


if __name__ == '__main__':
    unittest.main()
