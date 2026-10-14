import json
import os
import re
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


class PackageTests(unittest.TestCase):
    def test_symlinked_binary_is_packaged_as_a_regular_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / 'binary-link'
            binary.symlink_to('/usr/bin/true')
            subprocess.run(['python3', str(REPO / 'Integrations/Linux/package.py'), '--binary', str(binary),
                            '--version', '0.0.0-test', '--output', str(root)], check=True, capture_output=True)
            with tarfile.open(next(root.glob('*.tar.gz'))) as archive:
                member = next(item for item in archive.getmembers() if item.name.endswith('/bin/codexbar-linux'))
                self.assertTrue(member.isfile(), 'The packaged executable must not depend on a host symlink')
                self.assertEqual(member.mode, 0o755)
                self.assertEqual(archive.extractfile(member).read(), Path('/usr/bin/true').read_bytes())

    def test_archive_installs_without_a_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['python3', str(REPO / 'Integrations/Linux/package.py'), '--binary', '/usr/bin/true',
                            '--version', '0.0.0-test', '--output', str(root)], check=True, capture_output=True)
            archive_path = next(root.glob('*.tar.gz'))
            self.assertRegex(archive_path.name, r'^CodexBarDesktop-v0\.0\.0-test-linux-(x86_64|aarch64)\.tar\.gz$')
            subprocess.run([str(REPO / 'Scripts/generate_release_checksum.sh'), str(archive_path)],
                           check=True, capture_output=True)
            checksum = Path(str(archive_path) + '.sha256')
            self.assertEqual(checksum.read_text().split()[1], archive_path.name)
            patterns = (REPO / '.mac-release.env').read_text().splitlines()
            patterns = [line.rstrip("'").replace('${MARKETING_VERSION}', '0.0.0-test') for line in patterns
                        if line.startswith('^CodexBarDesktop-')]
            self.assertTrue(any(re.fullmatch(pattern, archive_path.name) for pattern in patterns))
            self.assertTrue(any(re.fullmatch(pattern, checksum.name) for pattern in patterns))
            with tarfile.open(archive_path) as archive:
                names = {name.split('/', 1)[1] for name in archive.getnames()}
                fixed = {'bin/codexbar-linux', 'README.md', 'LICENSE', 'THIRD_PARTY_NOTICES', 'Integrations/Linux/install.py',
                         'Integrations/Linux/icon.svg', 'Integrations/Omarchy/Panel.qml',
                         'Integrations/Omarchy/manifest.json'}
                logos = sorted((REPO / 'Sources/CodexBar/Resources').glob('ProviderIcon-*.svg'))
                self.assertTrue(logos)
                self.assertEqual(names, fixed | {f'Integrations/Omarchy/icons/{logo.name}' for logo in logos})
                self.assertFalse(any('linux.json' in name for name in archive.getnames()))
                notice = next(item for item in archive.getmembers() if item.name.endswith('/THIRD_PARTY_NOTICES'))
                self.assertIn(b'UNICODE LICENSE V3', archive.extractfile(notice).read())
                archive.extractall(root / 'unpacked', filter='data')
            package = next((root / 'unpacked').iterdir())
            home = root / 'home'
            env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / 'config'),
                       XDG_DATA_HOME=str(home / 'data'))
            subprocess.run(['python3', str(package / 'Integrations/Linux/install.py'), '--cli', '/usr/bin/true'],
                           env=env, check=True, capture_output=True)
            self.assertTrue((home / '.local/bin/codexbar-linux').is_file())
            shell = home / 'config/omarchy/shell.json'
            shell.parent.mkdir(parents=True)
            shell.write_text(json.dumps({'bar': {'layout': {'right': []}}}))
            for _ in range(2):
                subprocess.run(['python3', str(package / 'Integrations/Linux/install.py'),
                                '--cli', '/usr/bin/true', '--omarchy'], env=env, check=True, capture_output=True)
                installed = shell.parent / 'plugins/steipete.codexbar/icons'
                for logo in logos:
                    self.assertEqual((installed / logo.name).read_bytes(), logo.read_bytes())

    def test_invalid_version_does_not_create_an_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            for version in ['../escape', 'v1.2.3', '1.0;command', '1.0\nother']:
                result = subprocess.run(['python3', str(REPO / 'Integrations/Linux/package.py'),
                                         '--binary', '/usr/bin/true', '--version', version, '--output', temporary],
                                        capture_output=True)
                self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(Path(temporary).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
