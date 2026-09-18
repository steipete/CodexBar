#!/usr/bin/env python3
"""Exercise the SDK install boundary without network access or a real SDK."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


INSTALLER = Path(__file__).with_name("install_swift_static_sdk.sh")
ARCHIVE = b"synthetic Swift static SDK archive"


class StaticSDKInstallerTests(unittest.TestCase):
    def run_installer(self, *, checksum=None, curl_exit=0, swift_exit=0):
        with tempfile.TemporaryDirectory(prefix="codexbar sdk test ") as temporary:
            root = Path(temporary)
            binaries = root / "bin"
            binaries.mkdir()
            runner_temp = root / "runner temp"
            runner_temp.mkdir()
            record = root / "swift.json"
            curl = binaries / "curl"
            curl.write_text(
                f"#!{sys.executable}\n"
                "import os, pathlib, sys\n"
                "assert sys.argv[-1] == 'https://example.invalid/sdk.tar.gz'\n"
                "output = pathlib.Path(sys.argv[sys.argv.index('--output') + 1])\n"
                f"output.write_bytes({ARCHIVE!r})\n"
                "sys.exit(int(os.environ['TEST_CURL_EXIT']))\n"
            )
            swift = binaries / "swift"
            swift.write_text(
                f"#!{sys.executable}\n"
                "import hashlib, json, os, pathlib, sys\n"
                "assert sys.argv[1:3] == ['sdk', 'install']\n"
                "archive = pathlib.Path(sys.argv[3])\n"
                "data = {'path': str(archive), 'checksum': hashlib.sha256(archive.read_bytes()).hexdigest()}\n"
                "pathlib.Path(os.environ['TEST_SWIFT_RECORD']).write_text(json.dumps(data))\n"
                "sys.exit(int(os.environ['TEST_SWIFT_EXIT']))\n"
            )
            for executable in (curl, swift):
                executable.chmod(0o755)
            environment = {
                **os.environ,
                "PATH": f"{binaries}{os.pathsep}{os.environ['PATH']}",
                "RUNNER_TEMP": str(runner_temp),
                "SWIFT_STATIC_LINUX_SDK_URL": "https://example.invalid/sdk.tar.gz",
                "SWIFT_STATIC_LINUX_SDK_CHECKSUM": checksum or hashlib.sha256(ARCHIVE).hexdigest(),
                "TEST_CURL_EXIT": str(curl_exit),
                "TEST_SWIFT_EXIT": str(swift_exit),
                "TEST_SWIFT_RECORD": str(record),
            }
            result = subprocess.run([str(INSTALLER)], env=environment, capture_output=True, text=True, timeout=10)
            installed = json.loads(record.read_text()) if record.exists() else None
            self.assertEqual(list(runner_temp.iterdir()), [], "Temporary archives must be cleaned up")
            return result, installed

    def test_verified_archive_is_installed_from_a_local_path(self):
        result, installed = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(installed)
        self.assertTrue(Path(installed["path"]).is_absolute())
        self.assertTrue(installed["path"].endswith(".artifactbundle.tar.gz"))
        self.assertEqual(installed["checksum"], hashlib.sha256(ARCHIVE).hexdigest())

    def test_checksum_mismatch_prevents_installation(self):
        result, installed = self.run_installer(checksum="0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assertIsNone(installed)

    def test_download_failure_prevents_installation(self):
        result, installed = self.run_installer(curl_exit=22)
        self.assertEqual(result.returncode, 22)
        self.assertIsNone(installed)

    def test_installer_failure_is_not_hidden(self):
        result, installed = self.run_installer(swift_exit=11)
        self.assertEqual(result.returncode, 11)
        self.assertIsNotNone(installed)


if __name__ == "__main__":
    unittest.main()
