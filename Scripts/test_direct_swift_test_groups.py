#!/usr/bin/env python3
import json
import io
import errno
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import ci_swift_test_by_suite as runner
from direct_swift_test_groups import InventoryMismatch, checked, pool_timeout, prepare_runtime, run_pool, run_worker, runtime_environment, selected_tests, xctest_inventory


class DiscoveryHomeCleanupTests(unittest.TestCase):
    def test_discovery_unmounts_toolchain_before_removing_home(self):
        home = None
        mount = None
        mounted = True
        unlink = os.unlink

        def command(arguments, **kwargs):
            nonlocal home, mount, mounted
            if arguments == ["swift", "test", "list"]:
                home = Path(kwargs["env"]["HOME"])
                mount = home / "Library/Developer/Toolchains/Metal.xctoolchain"
                mount.mkdir(parents=True)
                (mount / "tool").write_text("synthetic toolchain")
                # A symlink to another mount must not authorize unmounting outside this home.
                (home / "outside").symlink_to("/Volumes", target_is_directory=True)
                return subprocess.CompletedProcess(arguments, 0, "CodexBarTests.Example/test()\n", "")
            self.assertEqual(arguments, ["/usr/sbin/diskutil", "unmount", str(mount)])
            self.assertTrue(kwargs["check"])
            mounted = False
            return subprocess.CompletedProcess(arguments, 0)

        def remove(path, *args, **kwargs):
            if mounted and Path(path).name == "tool":
                raise OSError(errno.EROFS, "Read-only file system", str(path))
            return unlink(path, *args, **kwargs)

        try:
            with patch.object(runner.sys, "platform", "darwin"), \
                    patch.object(runner.subprocess, "run", side_effect=command), \
                    patch.object(runner.os.path, "ismount", side_effect=lambda path:
                                 Path(path) == mount or Path(path).name == "outside"), \
                    patch.object(runner.os, "unlink", side_effect=remove):
                selections = runner.swift_test_list(["swift"])
            self.assertEqual([selection.name for selection in selections], ["CodexBarTests.Example"])
            self.assertFalse(mounted)
            self.assertFalse(home.exists())
        finally:
            if home is not None and home.exists():
                shutil.rmtree(home)

    def test_unmount_failure_is_not_suppressed_or_followed_by_deletion(self):
        with tempfile.TemporaryDirectory() as home:
            mount = Path(home) / "Metal.xctoolchain"
            mount.mkdir()
            error = subprocess.CalledProcessError(1, "diskutil")
            with patch.object(runner.sys, "platform", "darwin"), \
                    patch.object(runner.os.path, "ismount", return_value=True), \
                    patch.object(runner.subprocess, "run", side_effect=error), \
                    patch.object(runner.shutil, "rmtree") as remove:
                with self.assertRaises(subprocess.CalledProcessError):
                    runner.cleanup_discovery_home(home)
                remove.assert_not_called()

    def test_other_cleanup_errors_still_fail(self):
        with tempfile.TemporaryDirectory() as home:
            for error in [PermissionError(errno.EACCES, "denied"), OSError(errno.EROFS, "not a mount")]:
                with self.subTest(error=error), \
                        patch.object(runner.shutil, "rmtree", side_effect=error):
                    with self.assertRaises(OSError) as raised:
                        runner.cleanup_discovery_home(home)
                    self.assertIs(raised.exception, error)

    def test_directory_enumeration_errors_still_fail(self):
        error = PermissionError(errno.EACCES, "cannot inspect home")

        def walk(home, *, onerror):
            onerror(error)

        with patch.object(runner.sys, "platform", "darwin"), \
                patch.object(runner.os, "walk", side_effect=walk), \
                patch.object(runner.shutil, "rmtree") as remove:
            with self.assertRaises(PermissionError):
                runner.cleanup_discovery_home("synthetic-home")
            remove.assert_not_called()


class DirectSwiftTestGroupsTests(unittest.TestCase):
    def test_xctest_inventory_keeps_exact_method_identifiers(self):
        value = {"tests": [{"name": "All tests", "tests": [
            {"name": "CodexBarTests.ExampleTests", "tests": [{"name": "testFirst"}, {"name": "testSecond"}]}
        ]}]}
        self.assertEqual(xctest_inventory(value), ["CodexBarTests.ExampleTests/testFirst",
                                                  "CodexBarTests.ExampleTests/testSecond"])

    def test_group_filters_preserve_suite_and_top_level_selections(self):
        inventory = ["CodexBarTests.ExampleTests/testFirst", "CodexBarTests.OtherTests/testFirst",
                     "CodexBarTests.`top level test`()"]
        selections = [{"name": "CodexBarTests.ExampleTests", "suite_name": "CodexBarTests.ExampleTests",
                       "filter_pattern": r"^CodexBarTests\.ExampleTests/"}]
        self.assertEqual(selected_tests(inventory, selections), inventory[:1])
        selections.append({"name": "top level test", "suite_name": None,
                           "filter_pattern": r"CodexBarTests\..*top\ level\ test"})
        self.assertEqual(selected_tests(inventory, selections), [inventory[0], inventory[2]])

    def test_worker_environment_isolates_home_and_suppresses_keychain(self):
        with patch.dict(os.environ, {"HOME": "/synthetic/real-home", "CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS": "1",
                                     "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "0",
                                     "CODEXBAR_TEST_CODEX_FILE_FIXTURES": "inherited"}):
            environment = runtime_environment(Path("/synthetic/Xcode/Contents/Developer"), Path("/synthetic/group"))
        self.assertEqual(environment["CFFIXED_USER_HOME"], "/synthetic/group")
        self.assertEqual(environment["HOME"], "/synthetic/group")
        self.assertEqual(environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"], "1")
        self.assertNotIn("CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS", environment)
        self.assertNotIn("CODEXBAR_TEST_CODEX_FILE_FIXTURES", environment)

    def test_runtime_includes_private_frameworks_after_inherited_search_paths(self):
        with patch.dict(os.environ, {"DYLD_FRAMEWORK_PATH": "/synthetic/override"}, clear=True):
            environment = runtime_environment(Path("/synthetic/Developer"), Path("/synthetic/home"))
        self.assertEqual(environment["DYLD_FRAMEWORK_PATH"].split(":"), [
            "/synthetic/override",
            "/synthetic/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks",
            "/synthetic/Developer/Platforms/MacOSX.platform/Developer/Library/PrivateFrameworks",
        ])

    def test_failed_probe_names_helper_signal_and_redacts_stderr(self):
        output = io.StringIO()
        result = SimpleNamespace(returncode=-5, stdout="", stderr="dyld: missing framework; synthetic-secret")
        with patch("direct_swift_test_groups.subprocess.run", return_value=result), \
                patch("sys.stderr", output), patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, r"swiftpm-xctest-helper.*SIGTRAP"):
                checked(["/synthetic/swiftpm-xctest-helper"], {"API_TOKEN": "synthetic-secret"})
        self.assertIn("dyld: missing framework", output.getvalue())
        self.assertNotIn("synthetic-secret", output.getvalue())

    def test_crash_reports_are_fresh_process_scoped_and_redacted(self):
        from swift_test_diagnostics import print_crash_reports
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fresh = root / "swiftpm-xctest-helper-fresh.ips"
            fresh.write_text('Termination Reason: DYLD; synthetic-secret')
            old = root / "swiftpm-xctest-helper-old.crash"
            old.write_text("stale report must be excluded")
            os.utime(old, (1, 1))
            (root / "Unrelated-fresh.ips").write_text("unrelated report must be excluded")
            output = io.StringIO()
            with patch("sys.stderr", output), patch.dict(os.environ, {"API_TOKEN": "synthetic-secret"}, clear=True):
                self.assertEqual(print_crash_reports([root], 2), 1)
            self.assertIn("Termination Reason: DYLD", output.getvalue())
            for private in ["synthetic-secret", "stale report", "unrelated report"]:
                self.assertNotIn(private, output.getvalue())

    def test_diagnostics_redact_escaped_credentials_but_keep_nonsecret_controls(self):
        from swift_test_diagnostics import redact
        environment = {"API_TOKEN": 'synthetic-"secret"', "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1"}
        output = redact(json.dumps(environment) + " /Users/synthetic/Library test 1", environment)
        self.assertNotIn("secret", output)
        self.assertNotIn("/Users/synthetic/", output)
        self.assertIn("test 1", output)

    def test_worker_shares_deadline_across_frameworks_and_uses_exact_xctest_ids(self):
        group = [{"name": "ExampleTests", "suite_name": "ExampleTests", "filter_pattern": r"^ExampleTests/"}]
        runtime = {"developer": "/synthetic/Developer", "xctest": "synthetic-xctest",
                   "testing_helper": "synthetic-testing", "products": [{"bundle": "synthetic-bundle",
                   "binary": "synthetic-binary", "xctest": ["ExampleTests/testOne", "OtherTests/testTwo"],
                   "swift": ["ExampleTests/swiftTest()"]}]}
        calls = []
        def execute(command, timeout):
            calls.append((command, timeout, os.environ["CFFIXED_USER_HOME"], os.environ["SWIFT_TESTING_ENABLED"]))
            return 0
        with patch.dict(os.environ), patch("direct_swift_test_groups.run_command", side_effect=execute), \
                patch("direct_swift_test_groups.time.monotonic", side_effect=[10, 12, 17]):
            result = run_worker({"runtime": runtime, "groups": [group], "timeout": 10}, 0)
        self.assertEqual(result, 0)
        self.assertEqual(calls[0][0], ["synthetic-xctest", "-XCTest", "ExampleTests/testOne", "synthetic-bundle"])
        self.assertEqual([call[1] for call in calls], [8, 3])
        self.assertEqual([call[3] for call in calls], ["0", "1"])
        self.assertEqual(calls[0][2], calls[1][2])
        self.assertFalse(Path(calls[0][2]).exists())

    def test_worker_preserves_failure_after_running_other_frameworks(self):
        group = [{"name": "ExampleTests", "suite_name": "ExampleTests", "filter_pattern": r"^ExampleTests/"}]
        runtime = {"developer": "/synthetic/Developer", "xctest": "synthetic-xctest",
                   "testing_helper": "synthetic-testing", "products": [{"bundle": "synthetic-bundle",
                   "binary": "synthetic-binary", "xctest": ["ExampleTests/testOne"],
                   "swift": ["ExampleTests/swiftTest()"]}]}
        for codes in [[42, 0], [42, 23], [0, 23], [0, 124], [42, 124]]:
            with self.subTest(codes=codes), patch.dict(os.environ), \
                    patch("direct_swift_test_groups.run_command", side_effect=codes) as execute:
                self.assertEqual(run_worker({"runtime": runtime, "groups": [group], "timeout": 10}, 0),
                                 124 if 124 in codes else codes[0] or codes[1])
                self.assertEqual(execute.call_count, 2)

    def probe_runtime(self, swift_command, expected, *, different_toolchain=False, environment=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            developer = root / "Developer"
            frameworks = developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
            frameworks.mkdir(parents=True)
            swift = root / "toolchain/usr/bin/swift"
            helper_root = swift.parent.parent / "libexec/swift/pm"
            helper_root.mkdir(parents=True)
            for name in ["swiftpm-testing-helper", "swiftpm-xctest-helper"]:
                (helper_root / name).touch()
            xctest = root / "xctest"
            xctest.touch()
            binary = root / "bin/Example.xctest/Contents/MacOS/Example"
            binary.parent.mkdir(parents=True)
            binary.touch()
            def probe(command, environment):
                if command == ["xcode-select", "-p"]:
                    return str(developer)
                if command == ["xcrun", "--find", "swift"]:
                    return str(swift)
                if command == ["xcrun", "--find", "xctest"]:
                    return str(xctest)
                if command[-1] == "-print-target-info":
                    resource = "/other/toolchain" if different_toolchain and command[0] == swift_command[0] else str(swift.parent.parent / "lib/swift")
                    return json.dumps({"paths": {"runtimeResourcePath": resource},
                                       "target": {"triple": "arm64-apple-macosx"}})
                if command[-2:] == ["build", "--show-bin-path"]:
                    self.assertEqual(command[:-2], swift_command)
                    return str(root / "bin")
                if command[0].endswith("swiftpm-xctest-helper"):
                    self.assertEqual(environment["SWIFT_TESTING_ENABLED"], "0")
                    Path(command[2]).write_text('{"tests": []}')
                    return ""
                self.assertEqual(environment["SWIFT_TESTING_ENABLED"], "1")
                return "ExampleTests/changed()"
            with patch("direct_swift_test_groups.sys.platform", "darwin"), \
                    patch.dict(os.environ, environment or {}, clear=True), \
                    patch("direct_swift_test_groups.checked", side_effect=probe):
                return prepare_runtime(swift_command, [], expected, root)

    def test_inventory_mismatch_rejects_runtime_before_execution(self):
        with self.assertRaisesRegex(ValueError, "inventory differs"):
            self.probe_runtime(["swift"], ["ExampleTests/original()"])

    def test_selected_toolchain_wrapper_uses_its_build_directory(self):
        runtime = self.probe_runtime(["/synthetic/swift-native"], ["ExampleTests/changed()"])
        self.assertEqual(runtime["products"][0]["swift"], ["ExampleTests/changed()"])

    def test_hosted_ci_accepts_verified_inventory(self):
        for environment in [{"CI": "true"}, {"GITHUB_ACTIONS": "true"}]:
            with self.subTest(environment=environment):
                runtime = self.probe_runtime(["swift"], ["ExampleTests/changed()"], environment=environment)
                self.assertEqual(runtime["products"][0]["swift"], ["ExampleTests/changed()"])

    def test_hosted_ci_rejects_inventory_mismatch(self):
        with self.assertRaises(InventoryMismatch):
            self.probe_runtime(["swift"], ["ExampleTests/original()"], environment={"CI": "true"})

    def test_hosted_ci_unavailable_runtime_fails_without_serial_fallback(self):
        selection = runner.TestSelection("ExampleTests", "^ExampleTests/", "ExampleTests")
        output = io.StringIO()
        with patch.dict(os.environ, {"CI": "true"}), \
                patch.object(runner.sys, "argv", ["test.sh", "--direct-workers", "2"]), \
                patch.object(runner, "containment_support_error", return_value=None), \
                patch.object(runner, "swift_test_list", return_value=[selection]), \
                patch("direct_swift_test_groups.prepare_runtime", side_effect=ValueError("missing helper")), \
                patch.object(runner, "run_group", return_value=0) as serial, \
                patch.object(runner, "run_command") as direct, \
                patch.object(runner, "append_github_summary"), patch("sys.stdout", output), patch("sys.stderr", output):
            self.assertEqual(runner.main(), 2)
        self.assertIn("Direct mode refused", output.getvalue())
        serial.assert_not_called()
        direct.assert_not_called()

    def test_duplicate_swiftpm_inventory_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "inventory differs"):
            self.probe_runtime(["swift"], ["ExampleTests/changed()"] * 2)

    def test_wrapper_for_another_toolchain_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "selected Swift toolchain"):
            self.probe_runtime(["/synthetic/swift-native"], ["ExampleTests/changed()"], different_toolchain=True)

    def test_inventory_mismatch_fails_runner_without_serial_fallback(self):
        selection = runner.TestSelection("ExampleTests", "^ExampleTests/", "ExampleTests")
        output = io.StringIO()
        with patch.object(runner.sys, "argv", ["test.sh", "--direct-workers", "4"]), \
                patch.object(runner, "containment_support_error", return_value=None), \
                patch.object(runner, "swift_test_list", return_value=[selection]), \
                patch("direct_swift_test_groups.prepare_runtime", side_effect=InventoryMismatch("inventory differs")), \
                patch.object(runner, "run_group") as serial, patch.object(runner, "run_command") as direct, \
                patch.object(runner, "append_github_summary"), patch("sys.stdout", output), patch("sys.stderr", output):
            self.assertEqual(runner.main(), 2)
        self.assertIn("inventory differs", output.getvalue())
        serial.assert_not_called()
        direct.assert_not_called()

    def test_direct_and_serial_shards_keep_identical_ordered_groups(self):
        selections = [runner.TestSelection(name, f"^{name}/", name) for name in [
            "CodexBarTests.Alpha", "CodexBarTests.CLIEntryTests", "CodexBarTests.CostUsagePerformanceGateTests",
            "CodexBarTests.Delta", "CodexBarTests.Epsilon", "CodexBarTests.Zeta"]]
        for shard_count in [2, 3]:
            for shard_index in range(shard_count):
                serial_groups = []
                def run_serial(group, timeout, command):
                    serial_groups.append([runner.asdict(selection) for selection in group])
                    return 0
                args = ["test.sh", "--group-size", "2", "--shard-index", str(shard_index),
                        "--shard-count", str(shard_count), "--no-retry-non-timeout-failures"]
                with patch.object(runner, "containment_support_error", return_value=None), \
                        patch.object(runner, "swift_test_list", return_value=selections), \
                        patch.object(runner, "append_github_summary"), patch("sys.stdout", io.StringIO()), \
                        patch.object(runner.sys, "argv", args), \
                        patch.object(runner, "run_group", side_effect=run_serial):
                    self.assertEqual(runner.main(), 0)
                for workers in [2, 3]:
                    with self.subTest(shard_count=shard_count, shard_index=shard_index, workers=workers):
                        def execute(command, timeout):
                            manifest = json.loads(Path(command[-1]).read_text())
                            self.assertEqual(manifest["groups"], serial_groups)
                            self.assertEqual(manifest["workers"], workers)
                            self.assertFalse(manifest["retry_non_timeout_failures"])
                            return 0
                        with patch.dict(os.environ, {"CI": "true"}), \
                                patch.object(runner, "containment_support_error", return_value=None), \
                                patch.object(runner, "swift_test_list", return_value=selections), \
                                patch.object(runner, "append_github_summary"), patch("sys.stdout", io.StringIO()), \
                                patch.object(runner.sys, "argv", [*args, "--direct-workers", str(workers)]), \
                                patch("direct_swift_test_groups.prepare_runtime", return_value={"products": [{}]}) as prepare, \
                                patch.object(runner, "run_command", side_effect=execute), \
                                patch.object(runner, "run_group") as serial:
                            self.assertEqual(runner.main(), 0)
                        self.assertEqual(prepare.call_args.args[1], serial_groups)
                        serial.assert_not_called()

    def run_mock_pool(self, codes, group_size=1, retry=True, group_count=1, output=b""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"groups": [[{"name": str(index)} for index in range(group_size)]
                                                      for _ in range(group_count)],
                "timeout": 180, "workers": 1, "retry_non_timeout_failures": retry, "runtime": {"products": [{}]}}))
            codes = iter(codes)
            def run(command, **kwargs):
                kwargs["stdout"].buffer.write(output)
                return SimpleNamespace(returncode=next(codes))
            with patch("direct_swift_test_groups.subprocess.run", side_effect=run) as execute, \
                    patch("builtins.print"):
                result = run_pool(manifest)
            return result, json.loads((root / "results.json").read_text()), execute.call_count

    def test_non_utf8_test_output_does_not_replace_success(self):
        result, records, calls = self.run_mock_pool([0], output=b"synthetic diagnostic: \xff\n")
        self.assertEqual((result, records[0]["code"], calls), (0, 0, 1))

    def test_pool_stops_queued_groups_after_unrecovered_failure(self):
        for retry, codes, attempts in [(False, [42, 0, 0], 1), (True, [42, 42, 0, 0], 2)]:
            with self.subTest(retry=retry):
                result, records, calls = self.run_mock_pool(codes, group_size=2, retry=retry, group_count=3)
                self.assertEqual(result, 42)
                self.assertEqual(calls, attempts)
                self.assertEqual(len(records), 1)

    def test_pool_preserves_singleton_timeout_and_arbitrary_failure_codes(self):
        for code in [124, 42]:
            with self.subTest(code=code):
                result, records, calls = self.run_mock_pool([code])
                self.assertEqual(result, code)
                self.assertEqual(records[0]["code"], code)
                self.assertEqual(calls, 1)

    def test_pool_retains_first_failure_while_draining_other_workers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"groups": [[{"name": "first"}], [{"name": "second"}]],
                "workers": 2, "retry_non_timeout_failures": False}))
            release = threading.Event()
            drained = threading.Event()
            started = threading.Event()
            def execute(command, **kwargs):
                if command[-1] == "0":
                    self.assertTrue(started.wait(5))
                    return SimpleNamespace(returncode=42)
                started.set()
                self.assertTrue(release.wait(5))
                drained.set()
                return SimpleNamespace(returncode=124)
            def output(message, **kwargs):
                if message == "::endgroup::":
                    release.set()
            with patch("direct_swift_test_groups.subprocess.run", side_effect=execute), \
                    patch("builtins.print", side_effect=output):
                result = run_pool(manifest)
            self.assertEqual(result, 42)
            self.assertTrue(drained.is_set())
            self.assertEqual(len(json.loads((root / "results.json").read_text())), 2)

    def test_pool_budget_covers_all_isolated_recovery_attempts_and_cleanup(self):
        group = [{"name": str(index)} for index in range(12)]
        result, records, calls = self.run_mock_pool([124] + [0] * 12, group_size=12)
        self.assertEqual(result, 0)
        self.assertEqual(records[0]["isolated_retries"], 12)
        self.assertEqual(calls, 13)
        # Reporter's initial 180s timeout + twelve 150s successes exceeds the old 1620s budget.
        self.assertGreater(pool_timeout([group], 180, True, 5), 180 + 12 * 150)
        self.assertGreater(pool_timeout([group], 180, True, 5), 14 * 180)
        self.assertGreater(pool_timeout([group], 180, True, 5), pool_timeout([group], 180, False, 5))
        self.assertGreater(pool_timeout([group], 180, True, 5), pool_timeout([group], 180, True, 1))

    def test_pool_records_timeout_during_full_retry_even_when_recovery_succeeds(self):
        result, records, calls = self.run_mock_pool([1, 124, 0, 0], group_size=2)
        self.assertEqual(result, 0)
        self.assertEqual(records[0]["first_code"], 1)
        self.assertTrue(records[0]["timed_out"])
        self.assertEqual(records[0]["full_retries"], 1)
        self.assertEqual(records[0]["isolated_retries"], 2)
        self.assertEqual(calls, 4)

    def test_unsupported_platform_and_command_prefix_fall_back_before_probes(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch("direct_swift_test_groups.sys.platform", "linux"), patch("direct_swift_test_groups.checked") as probe:
                with self.assertRaises(ValueError):
                    prepare_runtime(["swift"], [], [], Path(directory))
                probe.assert_not_called()
            with patch("direct_swift_test_groups.sys.platform", "darwin"), patch.dict(os.environ, {}, clear=True):
                with patch("direct_swift_test_groups.checked") as probe:
                    with self.assertRaises(ValueError):
                        prepare_runtime(["swift", "--sdk", "/synthetic"], [], [], Path(directory))
                    probe.assert_not_called()


if __name__ == "__main__":
    unittest.main()
