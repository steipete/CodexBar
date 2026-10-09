#!/usr/bin/env python3

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import ci_swiftpm_cache as cache


class SwiftPMCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ci-input-cache-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)
        self.original_ns = time.time_ns() - 5_000_000_000
        self.names = ["Package.swift", "Sources/Main.swift", "Sources/probe.c", "Tests/Resources/fixture.md"]
        for name in self.names:
            self.write(name, "original\n", self.original_ns)
        self.git("add", ".")
        cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")

    def git(self, *arguments):
        subprocess.run(["git", *arguments], cwd=self.root, check=True, capture_output=True)

    def write(self, name, content, timestamp=None):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        if timestamp is not None:
            os.utime(path, ns=(timestamp, timestamp))
        return path

    def result(self, context="test-context"):
        return cache.restore(self.root, cache.DEFAULT_METADATA, context)

    def metadata(self, mutate):
        path = self.root / cache.DEFAULT_METADATA
        document = json.loads(path.read_text())
        mutate(document)
        path.write_text(json.dumps(document))

    def test_identical_contents_restore_swift_c_manifest_and_resource_timestamps(self):
        for name in self.names:
            self.write(name, "original\n")
        self.assertEqual(self.result()["restored"], len(self.names))
        for name in self.names:
            self.assertEqual((self.root / name).stat().st_mtime_ns, self.original_ns)
            self.assertEqual((self.root / name).read_text(), "original\n")

    def test_changed_same_size_content_is_not_given_old_timestamp(self):
        path = self.write("Sources/Main.swift", "modified\n")
        changed_ns = path.stat().st_mtime_ns
        result = self.result()
        self.assertEqual(result["changed"], 1)
        self.assertEqual(path.stat().st_mtime_ns, changed_ns)
        self.assertEqual(path.read_text(), "modified\n")

    def test_changed_content_with_preserved_or_older_timestamp_is_invalidated(self):
        for timestamp in (self.original_ns, self.original_ns - 1_000_000_000):
            with self.subTest(timestamp=timestamp):
                path = self.write("Sources/Main.swift", "modified\n", timestamp)
                self.assertEqual(self.result()["changed"], 1)
                self.assertGreater(path.stat().st_mtime_ns, self.original_ns)
                self.assertEqual(path.read_text(), "modified\n")

    def test_added_deleted_and_untracked_files_keep_checkout_state(self):
        path = self.write("Sources/Added.swift", "new\n")
        new_ns = path.stat().st_mtime_ns
        untracked = self.write("Sources/Untracked.swift", "untracked\n")
        untracked_ns = untracked.stat().st_mtime_ns
        (self.root / "Sources/Main.swift").unlink()
        self.git("add", "-A", "--", "Sources/Main.swift", "Sources/Added.swift")
        result = self.result()
        self.assertEqual(result["missing"], 1)
        self.assertFalse((self.root / "Sources/Main.swift").exists())
        self.assertEqual(path.stat().st_mtime_ns, new_ns)
        self.assertEqual(untracked.stat().st_mtime_ns, untracked_ns)

    def test_removed_resource_requires_clean_before_any_timestamp_is_restored(self):
        source = self.write("Sources/Main.swift", "original\n")
        fresh_ns = source.stat().st_mtime_ns
        (self.root / "Tests/Resources/fixture.md").unlink()
        self.git("add", "-A", "--", "Tests/Resources/fixture.md")
        result = self.result()
        self.assertIn("fallback", result)
        self.assertEqual(result["removed"], 1)
        self.assertEqual(result["restored"], 0)
        self.assertEqual(source.stat().st_mtime_ns, fresh_ns)

    def test_new_docs_do_not_invalidate_the_build_input_graph(self):
        self.write("docs/new.md", "documentation\n")
        self.git("add", "docs/new.md")
        result = self.result()
        self.assertNotIn("fallback", result)
        self.assertEqual(result["restored"], len(self.names))
        self.assertEqual(result["missing"], 1)

    def test_new_inputs_in_every_package_target_require_clean_fallback(self):
        for prefix in cache.BUILD_INPUT_PREFIXES:
            with self.subTest(prefix=prefix):
                name = prefix + "Added.swift"
                self.write(name, "new input\n")
                self.git("add", name)
                self.assertIn("fallback", self.result())
                self.assertEqual(self.result()["missing"], 1)
                self.git("rm", "--cached", "--", name)
                (self.root / name).unlink()

    def test_changed_git_or_filesystem_permissions_are_not_normalized(self):
        path = self.root / "Sources/probe.c"
        self.write("Sources/probe.c", "original\n")
        path.chmod(0o755)
        new_ns = path.stat().st_mtime_ns
        self.assertEqual(self.result()["changed"], 1)
        self.assertEqual(path.stat().st_mtime_ns, new_ns)
        self.assertEqual(path.stat().st_mode & 0o777, 0o755)
        self.git("add", "Sources/probe.c")
        self.assertEqual(self.result()["changed"], 1)

    def test_wrong_context_missing_and_malformed_metadata_fall_back_without_writes(self):
        path = self.write("Sources/Main.swift", "original\n")
        new_ns = path.stat().st_mtime_ns
        self.assertIn("fallback", self.result("other-toolchain"))
        metadata = self.root / cache.DEFAULT_METADATA
        metadata.write_text("{broken")
        self.assertIn("fallback", self.result())
        metadata.unlink()
        self.assertIn("fallback", self.result())
        self.assertEqual(path.stat().st_mtime_ns, new_ns)

    def test_malicious_paths_reject_entire_metadata_before_restoring_valid_records(self):
        for name in ("../outside", "/outside", "Sources/../outside", "Sources//Main.swift", "."):
            with self.subTest(name=name):
                cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
                path = self.write("Sources/Main.swift", "original\n")
                new_ns = path.stat().st_mtime_ns
                self.metadata(lambda doc: doc["files"].update({name: doc["files"]["Package.swift"]}))
                self.assertIn("fallback", self.result())
                self.assertEqual(path.stat().st_mtime_ns, new_ns)

    def test_invalid_records_reject_entire_metadata_before_any_write(self):
        for key, value in (("sha256", "bad"), ("mtime_ns", -1), ("mtime_ns", True), ("git_mode", "160000"), ("file_mode", -1), ("size", -1)):
            with self.subTest(key=key, value=value):
                cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
                path = self.write("Sources/Main.swift", "original\n")
                new_ns = path.stat().st_mtime_ns
                self.metadata(lambda doc: doc["files"]["Package.swift"].update({key: value}))
                self.assertIn("fallback", self.result())
                self.assertEqual(path.stat().st_mtime_ns, new_ns)

    def test_symlink_input_and_ancestor_cannot_write_outside_repository(self):
        with tempfile.TemporaryDirectory(prefix="ci-input-outside-") as external:
            outside = Path(external) / "Main.swift"
            outside.write_text("original\n")
            outside_ns = outside.stat().st_mtime_ns
            inside = self.root / "Sources/Main.swift"
            inside.unlink()
            inside.symlink_to(outside)
            self.assertEqual(self.result()["unavailable"], 1)
            self.assertEqual(outside.stat().st_mtime_ns, outside_ns)
            inside.unlink()
            (self.root / "Sources/probe.c").unlink()
            (self.root / "Sources").rmdir()
            (self.root / "Sources").symlink_to(external, target_is_directory=True)
            self.assertEqual(self.result()["unavailable"], 2)
            self.assertEqual(outside.stat().st_mtime_ns, outside_ns)

    def test_symlink_metadata_is_not_read(self):
        with tempfile.TemporaryDirectory(prefix="ci-input-meta-") as external:
            metadata = self.root / cache.DEFAULT_METADATA
            outside = Path(external) / "metadata.json"
            outside.write_bytes(metadata.read_bytes())
            metadata.unlink()
            metadata.symlink_to(outside)
            self.assertIn("fallback", self.result())

    def test_non_regular_metadata_and_excessive_json_depth_fall_back(self):
        metadata = self.root / cache.DEFAULT_METADATA
        metadata.unlink()
        os.mkfifo(metadata)
        self.assertIn("fallback", self.result())
        metadata.unlink()
        metadata.write_text("[" * 2000 + "0" + "]" * 2000)
        self.assertIn("fallback", self.result())

    def test_tracked_symlinks_record_payload_without_reading_or_writing_targets(self):
        with tempfile.TemporaryDirectory(prefix="ci-link-outside-") as external:
            outside = Path(external) / "Main.swift"
            outside.write_text("outside content\n")
            outside_ns = outside.stat().st_mtime_ns
            name = "TestsPlugin/Main.swift"
            link = self.root / name
            link.parent.mkdir()
            link.symlink_to(outside)
            self.git("add", name)
            cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
            record = json.loads((self.root / cache.DEFAULT_METADATA).read_text())["files"][name]
            self.assertEqual(record["git_mode"], "120000")
            self.assertEqual(record["sha256"], hashlib.sha256(os.fsencode(str(outside))).hexdigest())
            self.assertEqual(record["size"], len(os.fsencode(str(outside))))
            self.assertIn("fallback", self.result())
            self.assertEqual(outside.stat().st_mtime_ns, outside_ns)
            self.assertEqual(outside.read_text(), "outside content\n")

    def test_unchanged_link_to_untracked_backdated_target_requires_clean(self):
        target = self.write("Fixtures/Untracked.swift", "original\n", self.original_ns)
        link = self.root / "Sources/Linked.swift"
        link.symlink_to("../Fixtures/Untracked.swift")
        self.git("add", "Sources/Linked.swift")
        cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
        target.write_text("modified\n")
        os.utime(target, ns=(self.original_ns, self.original_ns))
        result = self.result()
        self.assertIn("fallback", result)
        self.assertEqual(result["restored"], 0)
        self.assertEqual(target.stat().st_mtime_ns, self.original_ns)

    def test_unchanged_link_to_deleted_tracked_target_requires_clean(self):
        self.write("Fixtures/Tracked.swift", "original\n", self.original_ns)
        link = self.root / "Sources/Linked.swift"
        link.symlink_to("../Fixtures/Tracked.swift")
        self.git("add", "Sources/Linked.swift", "Fixtures/Tracked.swift")
        cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
        self.git("rm", "--cached", "Fixtures/Tracked.swift")
        self.assertIn("fallback", self.result())
        self.assertEqual(self.result()["restored"], 0)

    def test_unchanged_link_to_tracked_backdated_target_invalidates_target(self):
        target = self.write("Fixtures/Tracked.swift", "original\n", self.original_ns)
        link = self.root / "Sources/Linked.swift"
        link.symlink_to("../Fixtures/Tracked.swift")
        self.git("add", "Sources/Linked.swift", "Fixtures/Tracked.swift")
        cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
        target.write_text("modified\n")
        os.utime(target, ns=(self.original_ns, self.original_ns))
        result = self.result()
        self.assertNotIn("fallback", result)
        self.assertEqual(result["changed"], 1)
        self.assertGreater(target.stat().st_mtime_ns, self.original_ns)

    def test_directory_and_chained_link_targets_require_clean(self):
        self.write("Fixtures/Tracked.swift", "original\n")
        (self.root / "Fixtures/Chain.swift").symlink_to("Tracked.swift")
        self.git("add", "Fixtures")
        for target in ("../Fixtures", "../Fixtures/Chain.swift"):
            with self.subTest(target=target):
                link = self.root / "Sources/Linked.swift"
                link.symlink_to(target)
                self.git("add", "Sources/Linked.swift")
                cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
                self.assertIn("fallback", self.result())
                self.assertEqual(self.result()["restored"], 0)
                link.unlink()

    def test_dotdot_cannot_hide_a_symlink_ancestor_in_a_link_target(self):
        self.write("Sources/Fixtures/Tracked.swift", "original\n")
        self.write("Outside/Fixtures/Tracked.swift", "modified\n")
        (self.root / "Outside/subdir").mkdir()
        (self.root / "Sources/route").symlink_to("../Outside/subdir")
        (self.root / "Sources/Linked.swift").symlink_to("route/../Fixtures/Tracked.swift")
        self.git("add", "Sources/Linked.swift", "Sources/Fixtures/Tracked.swift")
        cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
        self.assertIn("fallback", self.result())
        self.assertEqual(self.result()["restored"], 0)

    def test_clean_fallback_is_required_and_clean_failure_propagates(self):
        self.metadata(lambda document: document.update({"schema": cache.SCHEMA - 1}))
        arguments = ["ci_swiftpm_cache.py", "restore", "--root", str(self.root),
                     "--context", "test-context", "--clean-fallback"]
        with patch.object(sys, "argv", arguments), patch("builtins.print"), \
                patch.object(cache.subprocess, "run") as clean:
            cache.main()
            clean.assert_called_once_with(["swift", "package", "clean"], cwd=str(self.root), check=True)
            clean.side_effect = subprocess.CalledProcessError(1, "swift")
            with self.assertRaises(subprocess.CalledProcessError):
                cache.main()

    def test_unchanged_plugin_symlinks_allow_regular_input_timestamp_restoration(self):
        name = "TestsPlugin/Main.swift"
        link = self.root / name
        link.parent.mkdir()
        link.symlink_to("../Sources/Main.swift")
        self.git("add", name)
        cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
        link.unlink()
        link.symlink_to("../Sources/Main.swift")
        link_ns = link.lstat().st_mtime_ns
        for name in self.names:
            self.write(name, "original\n")
        result = self.result()
        self.assertNotIn("fallback", result)
        self.assertEqual(result["verified_symlinks"], 1)
        self.assertEqual(result["restored"], len(self.names))
        self.assertEqual(link.lstat().st_mtime_ns, link_ns)
        self.assertEqual((self.root / "Sources/Main.swift").stat().st_mtime_ns, self.original_ns)

    def test_same_size_retargeted_package_links_require_clean_before_any_timestamp_writes(self):
        for target, value in (("old", "original\n"), ("new", "modified\n")):
            self.write(f"Fixtures/{target}.swift", value, self.original_ns)
        self.git("add", "Fixtures")
        for prefix in cache.BUILD_INPUT_PREFIXES:
            for staged in (False, True):
                with self.subTest(prefix=prefix, staged=staged):
                    name = prefix + "Linked.swift"
                    link = self.root / name
                    link.parent.mkdir(parents=True, exist_ok=True)
                    link.symlink_to("../Fixtures/old.swift")
                    self.git("add", name)
                    cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
                    source = self.write("Sources/Main.swift", "original\n")
                    fresh_ns = source.stat().st_mtime_ns
                    link.unlink()
                    link.symlink_to("../Fixtures/new.swift")
                    if staged:
                        self.git("add", name)
                    result = self.result()
                    self.assertEqual(result["fallback"], "build input symlink target changed")
                    self.assertEqual(result["changed"], 1)
                    self.assertEqual(result["restored"], 0)
                    self.assertEqual(source.stat().st_mtime_ns, fresh_ns)
                    self.git("rm", "--cached", "--force", "--", name)
                    link.unlink()

    def test_added_and_removed_package_symlinks_require_clean(self):
        name = "TestsPlugin/Main.swift"
        link = self.root / name
        link.parent.mkdir()
        link.symlink_to("../Sources/Main.swift")
        self.git("add", name)
        added = self.result()
        self.assertEqual(added["fallback"], "build input paths changed")
        self.assertEqual(added["missing"], 1)
        self.assertEqual(added["restored"], 0)
        cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
        self.git("rm", "--force", "--", name)
        removed = self.result()
        self.assertEqual(removed["fallback"], "build input paths changed")
        self.assertEqual(removed["removed"], 1)
        self.assertEqual(removed["restored"], 0)

    def test_package_input_type_changes_require_clean_before_timestamp_writes(self):
        path = self.root / "Sources/Main.swift"
        for mode in ("symlink", "regular"):
            with self.subTest(mode=mode):
                path.unlink()
                if mode == "symlink":
                    path.symlink_to("probe.c")
                else:
                    self.write("Sources/Main.swift", "original\n")
                self.git("add", "Sources/Main.swift")
                unchanged = self.write("Package.swift", "original\n")
                fresh_ns = unchanged.stat().st_mtime_ns
                result = self.result()
                self.assertEqual(result["fallback"], "build input symlink type changed")
                self.assertEqual(result["restored"], 0)
                self.assertEqual(unchanged.stat().st_mtime_ns, fresh_ns)
                cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")

    def test_unverifiable_link_or_link_ancestor_requires_clean_without_outside_writes(self):
        name = "TestsPlugin/Main.swift"
        link = self.root / name
        link.parent.mkdir()
        link.symlink_to("../Sources/Main.swift")
        self.git("add", name)
        cache.snapshot(self.root, cache.DEFAULT_METADATA, "test-context")
        link.unlink()
        link.write_text("not a symlink\n")
        self.assertEqual(self.result()["unavailable"], 1)
        self.assertEqual(self.result()["restored"], 0)
        link.unlink()
        link.parent.rmdir()
        with tempfile.TemporaryDirectory(prefix="ci-link-parent-") as external:
            outside = Path(external) / "Main.swift"
            outside.symlink_to(self.root / "Sources/Main.swift")
            outside_ns = outside.lstat().st_mtime_ns
            link.parent.symlink_to(external, target_is_directory=True)
            self.assertEqual(self.result()["unavailable"], 1)
            self.assertEqual(self.result()["restored"], 0)
            self.assertEqual(outside.lstat().st_mtime_ns, outside_ns)

    def test_metadata_from_before_symlink_verification_requires_clean(self):
        path = self.write("Sources/Main.swift", "original\n")
        fresh_ns = path.stat().st_mtime_ns
        self.metadata(lambda document: document.update({"schema": cache.SCHEMA - 1}))
        self.assertEqual(self.result()["fallback"], "metadata schema mismatch")
        self.assertEqual(self.result()["restored"], 0)
        self.assertEqual(path.stat().st_mtime_ns, fresh_ns)

    def test_context_changes_with_toolchain_sdk_flags_and_dependencies(self):
        for name in cache.CONTEXT_INPUTS:
            self.write(name, "context-input\n")
        versions = {
            ("xcodebuild", "-version"): "Xcode test build",
            ("swift", "--version"): "Swift test version",
            ("swift", "build", "--help"): "default: native",
            ("xcrun", "--sdk", "macosx", "--show-sdk-path"): "/sdk",
            ("xcrun", "--sdk", "macosx", "--show-sdk-version"): "test-sdk",
            ("xcrun", "--sdk", "macosx", "--show-sdk-build-version"): "test-build",
        }
        with patch.object(cache.subprocess, "check_output", side_effect=lambda args, **_: versions[args]), \
                patch.object(cache.platform, "machine", return_value="arm64"):
            baseline = cache.build_context(self.root, "macos26-arm64")
            self.assertEqual(baseline, cache.build_context(self.root, "macos26-arm64"))
            self.assertNotEqual(baseline["context"], cache.build_context(self.root, "macos15-arm64")["context"])
            for arguments, version in list(versions.items()):
                with self.subTest(arguments=arguments):
                    versions[arguments] = version + "-changed"
                    self.assertNotEqual(baseline["context"], cache.build_context(self.root, "macos26-arm64")["context"])
                    versions[arguments] = version
            for name in cache.CONTEXT_INPUTS:
                with self.subTest(name=name):
                    self.write(name, "changed-context\n")
                    self.assertNotEqual(baseline["context"], cache.build_context(self.root, "macos26-arm64")["context"])
                    self.write(name, "context-input\n")
            with patch.object(cache.platform, "machine", return_value="x86_64"):
                self.assertNotEqual(baseline["context"], cache.build_context(self.root, "macos26-arm64")["context"])


if __name__ == "__main__":
    unittest.main()
