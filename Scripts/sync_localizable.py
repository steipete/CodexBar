#!/usr/bin/env python3
import argparse
import re
import sys
from pathlib import Path

ENTRY_RE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')


def parse_strings(path: Path) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("//") or line.startswith("/*"):
            continue
        match = ENTRY_RE.match(line)
        if not match:
            raise ValueError(f"Unsupported .strings line in {path}: {raw_line}")
        entries.append((match.group(1), match.group(2)))
    return entries


def render_strings(
    english_entries: list[tuple[str, str]],
    localized_values: dict[str, str],
    missing_keys: set[str],
) -> str:
    lines: list[str] = []
    for key, english_value in english_entries:
        if key in missing_keys:
            lines.append("/* TODO(l10n): review generated fallback translation. */")
        localized_value = localized_values.get(key, english_value)
        lines.append(f'"{key}" = "{localized_value}";')
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync zh-Hans Localizable.strings to en source.")
    parser.add_argument("--check", action="store_true", help="Fail if synchronization would change files.")
    parser.add_argument(
        "--source",
        default="Sources/CodexBar/Resources/en.lproj/Localizable.strings",
        help="Path to the source Localizable.strings file.",
    )
    parser.add_argument(
        "--target",
        default="Sources/CodexBar/Resources/zh-Hans.lproj/Localizable.strings",
        help="Path to the localized Localizable.strings file.",
    )
    args = parser.parse_args()

    source_path = Path(args.source)
    target_path = Path(args.target)
    english_entries = parse_strings(source_path)
    localized_entries = parse_strings(target_path)

    localized_map = dict(localized_entries)
    english_keys = [key for key, _ in english_entries]
    english_key_set = set(english_keys)
    missing_keys = {key for key in english_keys if key not in localized_map}

    # Drop stale keys by only rendering keys present in the English source.
    rendered = render_strings(english_entries, localized_map, missing_keys)
    current = target_path.read_text(encoding="utf-8")

    if current != rendered:
        if args.check:
            stale_keys = sorted(set(localized_map) - english_key_set)
            if missing_keys:
                print("Missing zh-Hans keys:", ", ".join(missing_keys), file=sys.stderr)
            if stale_keys:
                print("Stale zh-Hans keys:", ", ".join(stale_keys), file=sys.stderr)
            return 1
        target_path.write_text(rendered, encoding="utf-8")
        if missing_keys:
            print("Added fallback translations for:", ", ".join(sorted(missing_keys)))
        stale_keys = sorted(set(localized_map) - english_key_set)
        if stale_keys:
            print("Removed stale translations for:", ", ".join(stale_keys))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
