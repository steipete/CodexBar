#!/usr/bin/env python3

import importlib.util
import json
import os
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
        original_replace = os.replace
        replace_barrier = threading.Barrier(2)
        failures = []
        payloads = []

        def synchronized_replace(source, destination):
            replace_barrier.wait(timeout=10)
            return original_replace(source, destination)

        with tempfile.TemporaryDirectory(prefix="codexbar-mimo-cache-") as root:
            cache_path = Path(root) / "usage.json"
            module.CACHE_PATH = cache_path
            try:
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

                with patch.object(os, "replace", synchronized_replace):
                    writers = [threading.Thread(target=write_cache, args=(index,)) for index in (1, 2)]
                    for writer in writers:
                        writer.start()
                    for writer in writers:
                        writer.join(timeout=15)

                self.assertTrue(all(not writer.is_alive() for writer in writers))
                self.assertEqual(failures, [])
                self.assertEqual(len(payloads), 2)
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
                cache_path.write_text('{"previous": "complete cache"}')
                other_writer.write_text("another writer owns this file")

                def partial_write_then_fail(path, text, *args, **kwargs):
                    original_write_text(path, text[:10], *args, **kwargs)
                    raise OSError("synthetic write failure")

                failure = (
                    patch.object(Path, "write_text", partial_write_then_fail)
                    if failure_stage == "write"
                    else patch.object(os, "replace", side_effect=OSError("synthetic replace failure"))
                )
                with patch.object(module, "CACHE_PATH", cache_path), failure:
                    with self.assertRaisesRegex(OSError, f"synthetic {failure_stage} failure"):
                        module.write_cache({}, 0, None)

                self.assertEqual(json.loads(cache_path.read_text()), {"previous": "complete cache"})
                self.assertEqual(other_writer.read_text(), "another writer owns this file")
                self.assertEqual(set(Path(root).iterdir()), {cache_path, other_writer})


if __name__ == "__main__":
    unittest.main()
