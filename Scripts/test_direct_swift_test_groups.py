#!/usr/bin/env python3
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from direct_swift_test_groups import prepare_runtime, run_worker, runtime_environment, selected_tests, xctest_inventory


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
        with patch.dict(os.environ, {"CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS": "1",
                                     "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "0",
                                     "CODEXBAR_TEST_CODEX_FILE_FIXTURES": "inherited"}):
            environment = runtime_environment(Path("/synthetic/Xcode/Contents/Developer"), Path("/synthetic/group"))
        self.assertEqual(environment["CFFIXED_USER_HOME"], "/synthetic/group")
        self.assertEqual(environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"], "1")
        self.assertNotIn("CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS", environment)
        self.assertNotIn("CODEXBAR_TEST_CODEX_FILE_FIXTURES", environment)

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

    def test_worker_propagates_failure_without_running_other_frameworks(self):
        group = [{"name": "ExampleTests", "suite_name": "ExampleTests", "filter_pattern": r"^ExampleTests/"}]
        runtime = {"developer": "/synthetic/Developer", "xctest": "synthetic-xctest",
                   "testing_helper": "synthetic-testing", "products": [{"bundle": "synthetic-bundle",
                   "binary": "synthetic-binary", "xctest": ["ExampleTests/testOne"],
                   "swift": ["ExampleTests/swiftTest()"]}]}
        with patch.dict(os.environ), patch("direct_swift_test_groups.run_command", return_value=42) as execute:
            self.assertEqual(run_worker({"runtime": runtime, "groups": [group], "timeout": 10}, 0), 42)
            execute.assert_called_once()

    def test_inventory_mismatch_rejects_runtime_before_execution(self):
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
                if command == ["swift", "build", "--show-bin-path"]:
                    return str(root / "bin")
                if command[0].endswith("swiftpm-xctest-helper"):
                    Path(command[2]).write_text('{"tests": []}')
                    return ""
                return "ExampleTests/changed()"
            with patch("direct_swift_test_groups.sys.platform", "darwin"), \
                    patch.dict(os.environ, {}, clear=True), \
                    patch("direct_swift_test_groups.checked", side_effect=probe):
                with self.assertRaisesRegex(ValueError, "inventory differs"):
                    prepare_runtime(["swift"], [], ["ExampleTests/original()"], root)

    def test_hosted_ci_and_non_default_toolchain_fall_back_before_probes(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(os.environ, {"CI": "true"}), patch("direct_swift_test_groups.checked") as probe:
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
