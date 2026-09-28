#!/usr/bin/env python3
"""Black-box coverage for native test arguments and shared isolation."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from ci_swift_test_by_suite import ISOLATED_SUITES, TestSelection, shard_groups, test_groups

ROOT = Path(__file__).resolve().parent.parent


class NativeTestRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="codexbar-native-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.capture = self.directory / "arguments.json"
        binary = self.directory / "swift"
        binary.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "from pathlib import Path\n"
            "keys = ['CODEXBAR_TEST_CODEX_FILE_ISOLATION', 'CODEXBAR_TEST_SESSION_FILE_ISOLATION', "
            "'CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS', 'CODEXBAR_TEST_CODEX_FILE_FIXTURES', "
            "'DYLD_FRAMEWORK_PATH', 'MAKEFLAGS', 'MFLAGS', 'MAKEOVERRIDES']\n"
            "Path(os.environ['NATIVE_TEST_CAPTURE']).write_text(json.dumps("
            "{'arguments': sys.argv[1:], 'environment': {key: os.environ.get(key) for key in keys}}))\n"
            "if sys.argv[1:] == ['test', 'list']: print('CodexBarTests.FixtureTests/example()')\n"
            "raise SystemExit(int(os.environ.get('NATIVE_TEST_EXIT', '0')))\n",
            encoding="utf-8",
        )
        binary.chmod(0o755)
        self.environment = os.environ.copy()
        self.environment.update({
            "PATH": f"{self.directory}:{os.environ['PATH']}",
            "NATIVE_TEST_CAPTURE": str(self.capture),
            "CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS": "0",
            "CODEXBAR_TEST_CODEX_FILE_FIXTURES": "must-not-be-inherited",
            "CODEXBAR_TEST_NATIVE_TIMEOUT": "10",
        })
        self.environment.pop("CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS", None)
        self.environment.pop("DYLD_FRAMEWORK_PATH", None)

    def run_command(self, arguments):
        return subprocess.run(
            arguments, cwd=ROOT, env=self.environment, text=True,
            capture_output=True, timeout=20,
        )

    def test_native_arguments_and_repeated_filters_remain_literal(self):
        filters = ["(?<suite>AdaptiveRefreshPolicyTests)", r"Suite/has `spaces` and \\slashes"]
        arguments = ["--skip-build", "--filter", filters[0], "--filter", filters[1],
                     "--scratch-path", str(self.directory / "path with spaces"), "--parallel"]
        result = self.run_command(["bash", str(ROOT / "Scripts/test_fast.sh"), *arguments])
        self.assertEqual(result.returncode, 0, result.stderr)
        captured = json.loads(self.capture.read_text())
        self.assertEqual(captured["arguments"], ["test", "--no-parallel", *arguments])
        self.assertEqual(captured["environment"], {
            "CODEXBAR_TEST_CODEX_FILE_ISOLATION": "1",
            "CODEXBAR_TEST_SESSION_FILE_ISOLATION": "1",
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
            "CODEXBAR_TEST_CODEX_FILE_FIXTURES": None,
            "DYLD_FRAMEWORK_PATH": None,
            "MAKEFLAGS": None,
            "MFLAGS": None,
            "MAKEOVERRIDES": None,
        })

    def test_make_filters_cannot_execute_make_or_shell_expressions(self):
        sentinel = self.directory / "must-not-exist"
        value = f"(?<suite>Alpha)|`touch {sentinel}`|$(touch {sentinel})|$(shell touch {sentinel})|'quoted'"
        for target, prefix in [("test-fast", []), ("test-skip-build", ["--skip-build"])]:
            with self.subTest(target=target):
                result = self.run_command(["make", "-s", target, f"FILTER={value}"])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(sentinel.exists())
                self.assertEqual(json.loads(self.capture.read_text())["arguments"],
                                 ["test", "--no-parallel", *prefix, "--filter", value])

    def test_native_exit_code_is_preserved(self):
        self.environment["NATIVE_TEST_EXIT"] = "23"
        result = self.run_command(["bash", str(ROOT / "Scripts/test_fast.sh"), "--filter", "Example"])
        self.assertEqual(result.returncode, 23, result.stderr)

    def test_make_does_not_launch_swift_when_environment_setup_fails(self):
        for target in ["test-tty", "test-live"]:
            with self.subTest(target=target):
                self.capture.unlink(missing_ok=True)
                # This fixture directory intentionally has no Scripts/test_environment.sh.
                result = self.run_command([
                    "make", "-s", "-C", str(self.directory), "-f", str(ROOT / "Makefile"), target,
                ])
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.capture.exists())

    def test_scrubber_preserves_explicit_build_search_paths(self):
        for name in ["LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
                     "LIBRARY_PATH", "PKG_CONFIG_PATH"]:
            with self.subTest(name=name):
                # Assign inside Bash: macOS can strip DYLD variables when launching system binaries.
                probe = (f"export {name}=synthetic-build-path\n"
                         "source Scripts/test_environment.sh\n"
                         f'[[ "${{{name}:-}}" == synthetic-build-path ]]')
                result = self.run_command(["bash", "-c", probe])
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_deadline_fails_before_launch(self):
        for value in ["0", "-1", "invalid"]:
            with self.subTest(value=value):
                self.environment["CODEXBAR_TEST_NATIVE_TIMEOUT"] = value
                result = self.run_command(["bash", str(ROOT / "Scripts/test_fast.sh"), "--filter", "Example"])
                self.assertEqual(result.returncode, 2)
                self.assertIn("positive integer", result.stderr)
                self.assertFalse(self.capture.exists())

    def test_explicit_keychain_opt_in_retains_existing_policy(self):
        self.environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] = "1"
        for runner in ["test.sh", "test_fast.sh"]:
            with self.subTest(runner=runner):
                result = self.run_command(["bash", str(ROOT / "Scripts" / runner)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNone(json.loads(self.capture.read_text())["environment"]["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"])

    def test_both_runners_override_inherited_unsafe_test_environment(self):
        self.environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] = "0"
        for runner in ["test.sh", "test_fast.sh"]:
            with self.subTest(runner=runner):
                result = self.run_command(["bash", str(ROOT / "Scripts" / runner)])
                self.assertEqual(result.returncode, 0, result.stderr)
                environment = json.loads(self.capture.read_text())["environment"]
                self.assertEqual(environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"], "1")
                self.assertEqual(environment["CODEXBAR_TEST_CODEX_FILE_ISOLATION"], "1")
                self.assertEqual(environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"], "1")
                self.assertIsNone(environment["CODEXBAR_TEST_CODEX_FILE_FIXTURES"])

    def test_all_test_entry_points_scrub_secret_names(self):
        sensitive_names = [
            "CODEXBAR_TEST_SENTINEL_SECRET", "service_token", "Api_Key", "clientSECRET",
            "PASSWORD", "test_Passwd", "a_webhook_url", "CREDENTIAL_path", "CookieJar",
            "PRIVATE_FILE", "service_PAT", "CODEXBAR_API_KEY", "CODEXBAR_TEST_COOKIE",
        ]
        # The fake Swift process records only booleans, never inherited values.
        binary = self.directory / "swift"
        binary.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "from pathlib import Path\n"
            f"names = {sensitive_names!r}\n"
            "Path(os.environ['NATIVE_TEST_CAPTURE']).write_text(json.dumps({\n"
            "'secrets_absent': all(name not in os.environ for name in names),\n"
            "'ci_preserved': os.environ.get('CI') == 'true',\n"
            "'flag_preserved': os.environ.get('CODEXBAR_DISABLE_KEYCHAIN_ACCESS') == '1',\n"
            "'local_dependency_preserved': os.environ.get('CODEXBAR_USE_LOCAL_SWEETCOOKIEKIT') == '1',\n"
            "}))\n"
            "if sys.argv[1:] == ['test', 'list']: print('CodexBarTests.FixtureTests/example()')\n",
            encoding="utf-8",
        )
        self.environment.update(dict.fromkeys(sensitive_names, "sentinel-harness-secret"))
        self.environment.update(CI="true", CODEXBAR_DISABLE_KEYCHAIN_ACCESS="1",
                                CODEXBAR_USE_LOCAL_SWEETCOOKIEKIT="1")
        commands = [
            ["bash", "Scripts/test.sh"], ["bash", "Scripts/test_fast.sh"],
            ["bash", "Scripts/test-plugin-engines.sh"],
            *[["make", "-s", target] for target in
              ["test", "test-fast", "test-skip-build", "test-tty", "test-live"]],
        ]
        for command in commands:
            with self.subTest(command=command):
                result = self.run_command(command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(self.capture.read_text()), {
                    "secrets_absent": True, "ci_preserved": True, "flag_preserved": True,
                    "local_dependency_preserved": True,
                })


class TestGroupTests(unittest.TestCase):
    def test_expensive_suites_keep_their_own_deadline_without_losing_selections(self):
        names = ["CodexBarTests.Before", *sorted(ISOLATED_SUITES), "CodexBarTests.After"]
        selections = [TestSelection(name, f"^{name}/", name) for name in names]
        for size in [1, 4, 8, 12]:
            with self.subTest(size=size):
                groups = list(test_groups(selections, size))
                self.assertEqual([item for group in groups for item in group], selections)
                self.assertTrue(all(0 < len(group) <= size for group in groups))
                for group in groups:
                    if any(item.suite_name in ISOLATED_SUITES for item in group):
                        self.assertEqual(len(group), 1)
                sharded = [item for shard in range(2)
                           for group in shard_groups(groups, shard, 2) for item in group]
                self.assertCountEqual(sharded, selections)


if __name__ == "__main__":
    unittest.main()
