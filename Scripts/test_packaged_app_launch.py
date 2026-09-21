#!/usr/bin/env python3
"""Exercise smoke-launch isolation with harmless executables and a recorded sandbox profile."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest


class PackagedAppLaunchTests(unittest.TestCase):
    def test_all_launches_isolate_ambient_accounts_and_normal_launch_mode(self):
        script = Path(__file__).with_name("verify_packaged_app_launch.sh")
        with tempfile.TemporaryDirectory(prefix="codexbar-launch-fixture-") as directory:
            root = Path(directory)
            ambient = root / "ambient-home"
            ambient.mkdir()
            temporary = root / "temporary"
            temporary.mkdir()
            receipts = root / "receipts.jsonl"
            profiles = root / "profiles.jsonl"
            stubs = root / "bin"
            stubs.mkdir()
            app = root / "CodexBar.app"
            (app / "Contents/Helpers/CodexBar_CodexBarCore.bundle").mkdir(parents=True)
            child = f"#!{sys.executable}\n" + textwrap.dedent(f"""\
                import json, os, sys, time
                from pathlib import Path
                for key in ['SMOKE_AMBIENT_SENTINEL', 'CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS',
                            'CODEXBAR_TEST_CODEX_FILE_FIXTURES']:
                    assert key not in os.environ, key
                home = Path(os.environ['HOME'])
                assert home == Path(os.environ['CFFIXED_USER_HOME'])
                assert home.parent.name.startswith('codexbar-launch-smoke.')
                assert home.parent.parent == Path({str(temporary)!r})
                config = Path(os.environ['CODEXBAR_CONFIG'])
                assert config.is_relative_to(home)
                providers = json.loads(config.read_text())['providers']
                assert providers and all(p.get('enabled') is False for p in providers)
                assert Path(os.environ['XDG_CONFIG_HOME']).is_relative_to(home)
                assert Path(os.environ['TMPDIR']).is_relative_to(home.parent)
                assert os.environ['PATH'] == '/usr/bin:/bin:/usr/sbin:/sbin'
                for key in ['SWIFT_TESTING', 'CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS',
                            'CODEXBAR_TEST_CODEX_FILE_ISOLATION', 'CODEXBAR_TEST_SESSION_FILE_ISOLATION']:
                    assert os.environ[key] == '1', key
                resource = os.environ.get('CODEXBAR_RESOURCE_SMOKE')
                if resource is None:
                    args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
                    assert args['-iCloudSyncEnabled'] == 'NO'
                    assert args['-debugDisableKeychainAccess'] == 'YES'
                    assert args['-SUEnableAutomaticChecks'] == 'NO'
                    assert args['-SUAutomaticallyUpdate'] == 'NO'
                with open({str(receipts)!r}, 'a') as out:
                    out.write(json.dumps({{'executable': Path(sys.argv[0]).name, 'resource': resource}}) + '\\n')
                if resource == '1':
                    print('CODEXBAR_RESOURCE_SMOKE_OK')
                else:
                    time.sleep(60)
                """)
            for relative in ["Contents/MacOS/CodexBar", "Contents/Helpers/CodexBarCLI"]:
                executable = app / relative
                executable.parent.mkdir(parents=True, exist_ok=True)
                executable.write_text(child)
                executable.chmod(0o755)
            sandbox = stubs / "sandbox-exec"
            sandbox.write_text(f"#!{sys.executable}\n" + textwrap.dedent(f"""\
                import json, os, sys
                assert sys.argv[1] == '-p'
                with open({str(profiles)!r}, 'a') as out:
                    out.write(json.dumps(sys.argv[2]) + '\\n')
                os.execv(sys.argv[3], sys.argv[3:])
                """))
            sandbox.chmod(0o755)
            launchctl = stubs / "launchctl"
            launchctl.write_text("#!/bin/sh\nprintf 'Aqua\\n'\n")
            launchctl.chmod(0o755)
            environment = dict(
                os.environ,
                PATH=f"{stubs}:/usr/bin:/bin:/usr/sbin:/sbin",
                HOME=str(ambient),
                CFFIXED_USER_HOME=str(ambient),
                TMPDIR=str(temporary) + "/",
                CODEXBAR_CONFIG=str(ambient / "private-config.json"),
                CODEXBAR_SKIP_LAUNCH_SMOKE="0",
                CODEXBAR_LAUNCH_SMOKE_SECONDS="1",
                SMOKE_AMBIENT_SENTINEL="synthetic-only",
                CODEXBAR_RESOURCE_SMOKE="1",
                CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS="1",
                CODEXBAR_TEST_CODEX_FILE_FIXTURES="ambient-fixture-grant",
            )
            result = subprocess.run(
                ["/bin/bash", str(script), str(app)], env=environment,
                capture_output=True, text=True, timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            observations = [json.loads(line) for line in receipts.read_text().splitlines()]
            self.assertEqual([r["resource"] for r in observations], ["1", "1", "1", None])
            self.assertEqual([r["executable"] for r in observations],
                             ["CodexBarCLI", "codexbar", "CodexBar", "CodexBar"])
            sandbox_profiles = [json.loads(line) for line in profiles.read_text().splitlines()]
            self.assertEqual(len(sandbox_profiles), 4)
            for profile in sandbox_profiles:
                self.assertIn('(deny network*)', profile)
                self.assertIn(f'(deny file-read* (subpath "{script.parent.parent}"))', profile)
                self.assertIn(f'(deny file-write* (require-all (subpath "{ambient}")', profile)
                exception = re.search(r'\(require-not \(subpath "([^"]+)"\)\)', profile)
                self.assertIsNotNone(exception)
                smoke_root = Path(exception[1])
                self.assertEqual(smoke_root.parent, temporary)
                self.assertTrue(smoke_root.name.startswith("codexbar-launch-smoke."))
            self.assertFalse(list(ambient.iterdir()))
            self.assertFalse(list(temporary.iterdir()), "smoke launch left its child home or process files behind")


if __name__ == "__main__":
    unittest.main()
