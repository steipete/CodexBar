#!/usr/bin/env python3

import importlib.util
import json
from datetime import datetime, timezone
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch


def load_mimo_usage():
    script_path = Path(__file__).with_name("mimo-usage.py")
    spec = importlib.util.spec_from_file_location("mimo_usage", script_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load {script_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MiMoUsageCacheTests(unittest.TestCase):
    def test_concurrent_writers_publish_without_colliding(self):
        module = load_mimo_usage()
        original_cache_path = module.CACHE_PATH
        original_replace = Path.replace
        failures = []
        payloads = []
        temporary_paths = []
        staged_payloads = []

        with tempfile.TemporaryDirectory(prefix="codexbar-mimo-cache-") as root:
            cache_path = Path(root) / "usage.json"
            module.CACHE_PATH = cache_path
            try:
                def inspect_staged_payloads():
                    self.assertEqual(len(temporary_paths), 2)
                    self.assertEqual(len(set(temporary_paths)), 2)
                    for path in temporary_paths:
                        self.assertEqual(path.parent, cache_path.parent)
                        self.assertTrue(path.name.startswith(f".{cache_path.name}."))
                        self.assertEqual(path.suffix, ".tmp")
                        staged_payloads.append(json.loads(path.read_text()))
                    self.assertCountEqual([payload["sessions_scanned"] for payload in staged_payloads], [1, 2])
                    self.assertFalse(cache_path.exists())

                # The action runs while both writers are blocked, before either can publish.
                replace_barrier = threading.Barrier(2, action=inspect_staged_payloads)

                def synchronized_replace(source, destination):
                    self.assertEqual(destination, cache_path)
                    temporary_paths.append(source)
                    replace_barrier.wait(timeout=10)
                    return original_replace(source, destination)

                def write_cache(writer_id):
                    try:
                        usage = {
                            "input": writer_id * 100,
                            "output": writer_id * 10,
                            "cache_read": writer_id,
                            "cache_create": 0,
                            "messages": writer_id,
                        }
                        windows = {name: usage for name in ("today", "week", "all_time")}
                        payloads.append(module.write_cache(
                            windows, writer_id, datetime(2026, 1, writer_id, tzinfo=timezone.utc)))
                    except Exception as error:
                        failures.append(error)

                with patch.object(Path, "replace", synchronized_replace):
                    writers = [threading.Thread(target=write_cache, args=(index,)) for index in (1, 2)]
                    for writer in writers:
                        writer.start()
                    for writer in writers:
                        writer.join(timeout=15)

                self.assertTrue(all(not writer.is_alive() for writer in writers))
                self.assertEqual(failures, [])
                self.assertEqual(len(temporary_paths), 2, "Both writers must reach the publication hook")
                self.assertEqual(len(payloads), 2)
                self.assertCountEqual(staged_payloads, payloads)
                self.assertIn(json.loads(cache_path.read_text()), payloads)
                self.assertEqual(list(Path(root).iterdir()), [cache_path])
            finally:
                module.CACHE_PATH = original_cache_path

    def test_failed_publication_preserves_cache_and_other_writers_temporary_files(self):
        module = load_mimo_usage()
        original_write_text = Path.write_text

        for failure_stage in ("write", "replace"):
            with self.subTest(stage=failure_stage), tempfile.TemporaryDirectory(
                prefix="codexbar-mimo-failure-"
            ) as root:
                cache_path = Path(root) / "usage.json"
                other_writer = Path(root) / ".usage.json.other-writer.tmp"
                previous_cache = b'{"previous": "complete cache"}\n'
                other_writer_contents = b"another writer owns this file"
                cache_path.write_bytes(previous_cache)
                other_writer.write_bytes(other_writer_contents)
                failed_temporary_paths = []

                def partial_write_then_fail(path, text, *args, **kwargs):
                    failed_temporary_paths.append(path)
                    original_write_text(path, text[:10], *args, **kwargs)
                    self.assertEqual(path.read_text(), text[:10])
                    raise OSError("synthetic write failure")

                def fail_replace(path, destination):
                    failed_temporary_paths.append(path)
                    self.assertEqual(destination, cache_path)
                    staged_payload = json.loads(path.read_text())
                    self.assertEqual(staged_payload["windows"], {})
                    self.assertEqual(staged_payload["sessions_scanned"], 0)
                    raise OSError("synthetic replace failure")

                failure = (
                    patch.object(Path, "write_text", partial_write_then_fail)
                    if failure_stage == "write"
                    else patch.object(Path, "replace", fail_replace)
                )
                with patch.object(module, "CACHE_PATH", cache_path), failure:
                    with self.assertRaisesRegex(OSError, f"synthetic {failure_stage} failure"):
                        module.write_cache({}, 0, None)

                self.assertEqual(len(failed_temporary_paths), 1, "The failure hook must run exactly once")
                failed_path = failed_temporary_paths[0]
                self.assertEqual(failed_path.parent, cache_path.parent)
                self.assertTrue(failed_path.name.startswith(f".{cache_path.name}."))
                self.assertEqual(failed_path.suffix, ".tmp")
                self.assertNotEqual(failed_path, other_writer)
                self.assertFalse(failed_path.exists())
                self.assertEqual(cache_path.read_bytes(), previous_cache)
                self.assertEqual(other_writer.read_bytes(), other_writer_contents)
                self.assertEqual(set(Path(root).iterdir()), {cache_path, other_writer})


if __name__ == "__main__":
    unittest.main()
