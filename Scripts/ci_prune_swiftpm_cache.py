#!/usr/bin/env python3
"""Keep one completed compiled-input cache per active macOS lane on main; drop retired lanes."""

import argparse
from datetime import datetime
import json
import re
import subprocess

# Must match ci_swiftpm_cache.LANES; retired lanes are never restored again, so none of their snapshots are kept.
ACTIVE_LANES = ("xcode27-arm64",)
RETIRED_LANES = ("macos26-arm64", "macos15-arm64")
KEY = re.compile(
    r"swiftpm-compiled-v1-(" + "|".join(map(re.escape, ACTIVE_LANES + RETIRED_LANES)) + r")-[a-f0-9]{64}-[a-f0-9]{40}"
)


def obsolete_caches(entries):
    lanes = {}
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("ref") != "refs/heads/main":
            continue
        match = KEY.fullmatch(str(entry.get("key", "")))
        if match is None or type(entry.get("id")) is not int or entry["id"] <= 0:
            continue
        try:
            created = datetime.fromisoformat(entry["created_at"].replace("Z", "+00:00"))
            if created.tzinfo is None:
                continue
        except (KeyError, ValueError, TypeError, AttributeError):
            continue
        lanes.setdefault(match[1], []).append((created, entry["id"]))
    # Only the new, fully specified namespace is eligible; legacy and PR caches
    # cannot be selected even if their names partially resemble a compiled key.
    obsolete = []
    for lane, values in lanes.items():
        keep = 0 if lane in RETIRED_LANES else 1
        obsolete.extend(identifier for _, identifier in sorted(values, reverse=True)[keep:])
    return sorted(obsolete)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        parser.error("invalid GitHub repository")
    endpoint = f"repos/{args.repository}/actions/caches"
    pages = json.loads(subprocess.check_output(
        ["gh", "api", "--paginate", "--slurp", f"{endpoint}?per_page=100"], text=True
    ))
    entries = [entry for page in pages for entry in page["actions_caches"]]
    identifiers = obsolete_caches(entries)
    for identifier in identifiers:
        subprocess.run(["gh", "api", "--method", "DELETE", f"{endpoint}/{identifier}"], check=True)
    print(json.dumps({"deleted": len(identifiers)}))


if __name__ == "__main__":
    main()
