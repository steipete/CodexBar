#!/usr/bin/env python3
"""Run SwiftPM tests in suite shards so CI cannot hang inside one aggregate run."""

from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
from collections.abc import Iterable
from dataclasses import dataclass


@dataclass(frozen=True)
class TestSelection:
    name: str
    filter_pattern: str
    suite_name: str | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--group-size", type=int, default=12)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--limit-groups", type=int)
    parser.add_argument("--shard-index", type=int)
    parser.add_argument("--shard-count", type=int)
    parser.add_argument("--list-only", action="store_true")
    parser.add_argument("--swift-command", default="swift")
    parser.add_argument("--swift-command-arg", action="append", default=[])
    return parser.parse_args()


def run_command(command: list[str], timeout: int | None = None) -> int:
    print(f"+ {' '.join(command)}", flush=True)
    process = subprocess.Popen(command, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"::warning::Command timed out after {timeout}s: {' '.join(command)}", flush=True)
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        return 124


def swift_test_list(swift_command: list[str]) -> list[TestSelection]:
    result = subprocess.run([*swift_command, "test", "list"], check=True, capture_output=True, text=True)
    selections: set[TestSelection] = set()
    unknown: list[str] = []
    for line in result.stdout.splitlines():
        top_level = re.fullmatch(r"(?P<module>[^.]+)\.(?:`(?P<display>.+)`|(?P<function>[^()/]+))\(\)", line)
        if top_level is not None:
            module = top_level.group("module")
            test_name = top_level.group("display") or top_level.group("function")
            selections.add(
                TestSelection(
                    name=line,
                    # SwiftPM matches top-level Swift Testing functions by their display name,
                    # not the backtick-wrapped identifier printed by `swift test list`.
                    filter_pattern=rf"{re.escape(module)}\..*{re.escape(test_name)}",
                )
            )
            continue

        if "/" in line:
            suite = line.split("/", 1)[0]
            if "." in suite:
                selections.add(
                    TestSelection(
                        name=suite,
                        filter_pattern=rf"^{re.escape(suite)}/",
                        suite_name=suite,
                    )
                )
                continue

        unknown.append(line)

    if unknown:
        rendered = "\n".join(f"- {line}" for line in unknown)
        raise RuntimeError(f"Unrecognized `swift test list` output:\n{rendered}")
    return sorted(selections, key=lambda selection: selection.name)


def chunks(items: list[TestSelection], size: int) -> Iterable[list[TestSelection]]:
    for index in range(0, len(items), size):
        yield items[index : index + size]


def shard_groups(groups: list[list[TestSelection]], shard_index: int | None, shard_count: int | None) -> list[list[TestSelection]]:
    if shard_index is None and shard_count is None:
        return groups
    if shard_index is None or shard_count is None:
        raise ValueError("--shard-index and --shard-count must be passed together")
    if shard_count < 1:
        raise ValueError("--shard-count must be positive")
    if shard_index < 0 or shard_index >= shard_count:
        raise ValueError("--shard-index must be in the range [0, --shard-count)")
    return [group for index, group in enumerate(groups) if index % shard_count == shard_index]


def prioritized_suites(suites: list[TestSelection]) -> list[TestSelection]:
    priority = ["CodexBarTests.CLIEntryTests"]
    ordered = [suite for name in priority for suite in suites if suite.suite_name == name]
    ordered.extend(suite for suite in suites if suite.suite_name not in priority)
    return ordered


def filtered_suites_for_environment(suites: list[TestSelection]) -> list[TestSelection]:
    if os.environ.get("GITHUB_ACTIONS") != "true" or sys.platform != "darwin":
        return suites

    # SwiftPM hangs before suite output for this executable-target suite on the Intel macOS runner.
    # Linux CI still runs it in the full Swift test lane, and local macOS runs it directly.
    skipped = {"CodexBarTests.CLIEntryTests"}
    filtered = [suite for suite in suites if suite.suite_name not in skipped]
    if len(filtered) != len(suites):
        print(f"Skipping macOS CI-only suites: {', '.join(sorted(skipped))}", flush=True)
    return filtered


def filter_for(suites: list[TestSelection]) -> str:
    return rf"({'|'.join(suite.filter_pattern for suite in suites)})"


def run_group(suites: list[TestSelection], timeout: int, swift_command: list[str]) -> int:
    return run_command(
        [*swift_command, "test", "--no-parallel", "--filter", filter_for(suites)],
        timeout=timeout,
    )


def main() -> int:
    args = parse_args()
    if args.group_size < 1:
        print("--group-size must be positive", file=sys.stderr)
        return 2

    swift_command = [args.swift_command, *args.swift_command_arg]
    suites = prioritized_suites(filtered_suites_for_environment(swift_test_list(swift_command)))
    suite_groups = list(chunks(suites, args.group_size))
    try:
        suite_groups = shard_groups(suite_groups, args.shard_index, args.shard_count)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    if args.limit_groups is not None:
        suite_groups = suite_groups[: args.limit_groups]

    shard_suffix = ""
    if args.shard_index is not None and args.shard_count is not None:
        shard_suffix = f" in shard {args.shard_index + 1}/{args.shard_count}"
    print(f"Discovered {len(suites)} test selections; running {len(suite_groups)} groups{shard_suffix}", flush=True)
    if args.list_only:
        for group in suite_groups:
            for suite in group:
                print(suite.name)
        return 0

    if not suite_groups:
        print("No test groups selected.", flush=True)
        return 0

    for group_index, group in enumerate(suite_groups, start=1):
        print(
            f"::group::Swift test shard {group_index}/{len(suite_groups)} "
            f"({len(group)} selections)",
            flush=True,
        )
        result = run_group(group, args.timeout, swift_command)
        print("::endgroup::", flush=True)
        if result == 0:
            continue
        if len(group) == 1:
            return result

        if result != 124:
            print(f"Shard {group_index} failed with exit code {result}; retrying shard once", flush=True)
            retry_result = run_group(group, args.timeout, swift_command)
            if retry_result == 0:
                continue
            return retry_result

        print(f"Shard {group_index} timed out; retrying suites one at a time", flush=True)
        for suite in group:
            print(f"::group::Swift test retry {suite.name}", flush=True)
            retry_result = run_group([suite], args.timeout, swift_command)
            print("::endgroup::", flush=True)
            if retry_result != 0:
                return retry_result

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
