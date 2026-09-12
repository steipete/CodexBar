import os
import re
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


class PackageTests(unittest.TestCase):
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
                self.assertEqual(len(archive.getmembers()), 7)
                self.assertFalse(any('linux.json' in name for name in archive.getnames()))
                archive.extractall(root / 'unpacked', filter='data')
            package = next((root / 'unpacked').iterdir())
            home = root / 'home'
            env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / 'config'),
                       XDG_DATA_HOME=str(home / 'data'))
            subprocess.run(['python3', str(package / 'Integrations/Linux/install.py'), '--cli', '/usr/bin/true'],
                           env=env, check=True, capture_output=True)
            self.assertTrue((home / '.local/bin/codexbar-linux').is_file())

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
