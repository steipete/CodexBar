import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'install-omarchy.py'
spec = importlib.util.spec_from_file_location('install_omarchy', SCRIPT)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class OmarchyInstall(unittest.TestCase):
    def test_keeps_other_widgets_and_backs_up_existing_adapter(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shell = root / 'omarchy/shell.json'
            plugin = root / 'omarchy/plugins/steipete.codexbar'
            plugin.mkdir(parents=True)
            (plugin / 'Panel.qml').write_text('previous adapter')
            before = {'bar': {'layout': {'right': [
                {'id': 'steipete.codexbar', 'desktopExecutable': '/old/app'},
                {'id': 'omarchy.tray', 'pinned': ['other-app', 'codexbar-rust-prototype']},
                {'id': 'omarchy.clock', 'format': 'HH:mm'}]}}, 'unrelated': {'setting': True}}
            shell.write_text(json.dumps(before))
            binary = root / 'prototype'
            binary.write_text('#!/bin/sh\nexit 0\n')
            binary.chmod(0o700)
            backup = installer.install(root, binary)
            after = json.loads(shell.read_text())
            self.assertEqual(json.loads((backup / 'shell.json').read_text()), before)
            self.assertEqual((backup / 'steipete.codexbar/Panel.qml').read_text(), 'previous adapter')
            self.assertEqual(after['unrelated'], before['unrelated'])
            self.assertEqual(after['bar']['layout']['right'][2], before['bar']['layout']['right'][2])
            self.assertEqual(after['bar']['layout']['right'][1]['pinned'], ['other-app'])
            self.assertEqual(after['bar']['layout']['right'][0]['desktopExecutable'], str(binary))

    def test_invalid_shell_is_untouched(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shell = root / 'omarchy/shell.json'
            shell.parent.mkdir()
            shell.write_text('{broken')
            with self.assertRaises(ValueError):
                installer.install(root, Path('/bin/true'))
            self.assertEqual(shell.read_text(), '{broken')
            self.assertFalse((root / 'omarchy/plugins').exists())


if __name__ == '__main__':
    unittest.main()
