#!/usr/bin/env python3

import unittest

from ci_prune_swiftpm_cache import ACTIVE_LANES, obsolete_caches
from ci_swiftpm_cache import LANES


def entry(identifier, lane="xcode27-arm64", **overrides):
    return {
        "id": identifier, "ref": "refs/heads/main",
        "key": f"swiftpm-compiled-v1-{lane}-{'a' * 64}-{'b' * 40}",
        "created_at": f"2026-01-{identifier:02d}T00:00:00Z", **overrides,
    }


class PruneCacheTests(unittest.TestCase):
    def test_keeps_newest_main_snapshot_per_lane_even_after_toolchain_change(self):
        caches = [entry(1), entry(3), entry(2)]
        caches[1]["key"] = caches[1]["key"].replace("a" * 64, "c" * 64)
        self.assertEqual(obsolete_caches(caches), [1, 2])

    def test_deletes_every_snapshot_from_retired_lanes(self):
        caches = [entry(1), entry(2, "macos26-arm64"), entry(3, "macos15-arm64"), entry(4, "macos15-arm64")]
        self.assertEqual(obsolete_caches(caches), [2, 3, 4])

    def test_active_lanes_match_the_cache_builder(self):
        self.assertEqual(ACTIVE_LANES, LANES)

    def test_never_selects_legacy_other_namespace_or_non_main_caches(self):
        untouched = [
            entry(1, key="swiftpm-macos26-arm64-legacy"),
            entry(2, ref="refs/pull/1/merge"), entry(3, ref="refs/heads/other"),
            entry(4, key="swiftpm-compiled-v2-macos26-arm64-other"),
            entry(5, "linux-x64"), entry(6, key=entry(6)["key"] + "-suffix"),
        ]
        self.assertEqual(obsolete_caches(untouched + [entry(7)]), [])

    def test_invalid_entries_are_ignored(self):
        invalid = [None, {}, entry(1, id=True), entry(2, id=-1), entry(3, created_at="invalid"),
                   entry(4, created_at="2026-01-01T00:00:00"), entry(5, created_at=None)]
        self.assertEqual(obsolete_caches(invalid + [entry(6)]), [])


if __name__ == "__main__":
    unittest.main()
