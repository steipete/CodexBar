#!/usr/bin/env python3
"""Run SwiftPM tests in suite shards so CI cannot hang inside one aggregate run."""

from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import time
from collections.abc import Iterable
from dataclasses import dataclass


@dataclass(frozen=True)
class TestSelection:
    name: str
    filter_pattern: str
    suite_name: str | None = None


@dataclass
class RunStats:
    discovered_selections: int = 0
    selected_selections: int = 0
    selected_groups: int = 0
    group_size: int = 0
    shard_index: int | None = None
    shard_count: int | None = None
    discovery_seconds: float = 0
    execution_seconds: float = 0
    total_seconds: float = 0
    first_pass_successful_groups: int = 0
    first_pass_failed_groups: int = 0
    full_group_retries: int = 0
    timed_out_groups: int = 0
    recovered_groups: int = 0
    isolated_selection_retries: int = 0

    def summary_rows(self) -> list[tuple[str, str]]:
        shard = "none"
        if self.shard_index is not None and self.shard_count is not None:
            shard = f"{self.shard_index + 1}/{self.shard_count}"
        return [
            ("Shard", shard),
            ("Group size", str(self.group_size)),
            ("Discovered selections", str(self.discovered_selections)),
            ("Selected selections", str(self.selected_selections)),
            ("Selected groups", str(self.selected_groups)),
            ("First-pass successful groups", str(self.first_pass_successful_groups)),
            ("First-pass failed groups", str(self.first_pass_failed_groups)),
            ("Full-group retries", str(self.full_group_retries)),
            ("Recovered groups", str(self.recovered_groups)),
            ("Timed out groups", str(self.timed_out_groups)),
            ("Isolated selection retries", str(self.isolated_selection_retries)),
            ("Discovery seconds", f"{self.discovery_seconds:.1f}"),
            ("Execution seconds", f"{self.execution_seconds:.1f}"),
            ("Total seconds", f"{self.total_seconds:.1f}"),
        ]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--group-size", type=int, default=12)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--limit-groups", type=int)
    parser.add_argument("--shard-index", type=int)
    parser.add_argument("--shard-count", type=int)
    parser.add_argument(
        "--no-retry-non-timeout-failures",
        action="store_false",
        dest="retry_non_timeout_failures",
        help="fail immediately when a group exits without timing out",
    )
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
    command = [*swift_command, "test", "list"]
    try:
        result = subprocess.run(command, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        print(f"+ {swift_command[0]} test list", flush=True)
        if error.stdout:
            print(error.stdout, end="" if error.stdout.endswith("\n") else "\n", flush=True)
        if error.stderr:
            print(error.stderr, end="" if error.stderr.endswith("\n") else "\n", file=sys.stderr, flush=True)
        raise
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


def append_github_summary(stats: RunStats) -> None:
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return

    with open(summary_path, "a", encoding="utf-8") as summary:
        summary.write("### macOS Swift test timing\n\n")
        summary.write("| Field | Value |\n")
        summary.write("| --- | --- |\n")
        for field, value in stats.summary_rows():
            safe_value = value.replace("|", "\\|")
            summary.write(f"| {field} | `{safe_value}` |\n")
        summary.write("\n")


def print_timing_summary(stats: RunStats) -> None:
    print("Swift test timing summary:", flush=True)
    for field, value in stats.summary_rows():
        print(f"- {field}: {value}", flush=True)


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
        [*swift_command, "test", "--skip-build", "--no-parallel", "--filter", filter_for(suites)],
        timeout=timeout,
    )


def retry_selections_individually(
    suites: list[TestSelection],
    timeout: int,
    swift_command: list[str],
    stats: RunStats,
) -> int:
    for suite in suites:
        stats.isolated_selection_retries += 1
        print(f"::group::Swift test retry {suite.name}", flush=True)
        retry_result = run_group([suite], timeout, swift_command)
        print("::endgroup::", flush=True)
        if retry_result != 0:
            return retry_result
    return 0


def main() -> int:
    total_started = time.monotonic()
    args = parse_args()
    stats = RunStats(
        group_size=args.group_size,
        shard_index=args.shard_index,
        shard_count=args.shard_count,
    )
    if args.group_size < 1:
        print("--group-size must be positive", file=sys.stderr)
        return 2

    swift_command = [args.swift_command, *args.swift_command_arg]
    result = 0
    try:
        discovery_started = time.monotonic()
        try:
            suites = prioritized_suites(filtered_suites_for_environment(swift_test_list(swift_command)))
        finally:
            stats.discovery_seconds = time.monotonic() - discovery_started
        stats.discovered_selections = len(suites)

        suite_groups = list(chunks(suites, args.group_size))
        try:
            suite_groups = shard_groups(suite_groups, args.shard_index, args.shard_count)
        except ValueError as error:
            print(str(error), file=sys.stderr)
            result = 2
            return result
        if args.limit_groups is not None:
            suite_groups = suite_groups[: args.limit_groups]
        stats.selected_selections = sum(len(group) for group in suite_groups)
        stats.selected_groups = len(suite_groups)

        shard_suffix = ""
        if args.shard_index is not None and args.shard_count is not None:
            shard_suffix = f" in shard {args.shard_index + 1}/{args.shard_count}"
        print(
            f"Discovered {len(suites)} test selections; running {stats.selected_selections} selections "
            f"in {len(suite_groups)} groups{shard_suffix}",
            flush=True,
        )
        if args.list_only:
            for group in suite_groups:
                for suite in group:
                    print(suite.name)
            return 0

        if not suite_groups:
            print("No test groups selected.", flush=True)
            return 0

        execution_started = time.monotonic()
        for group_index, group in enumerate(suite_groups, start=1):
            print(
                f"::group::Swift test group {group_index}/{len(suite_groups)} "
                f"({len(group)} selections)",
                flush=True,
            )
            group_result = run_group(group, args.timeout, swift_command)
            print("::endgroup::", flush=True)
            if group_result == 0:
                stats.first_pass_successful_groups += 1
                continue

            stats.first_pass_failed_groups += 1
            group_timed_out = group_result == 124
            if group_timed_out:
                stats.timed_out_groups += 1
            if len(group) == 1:
                result = group_result
                return result

            if group_result != 124:
                if not args.retry_non_timeout_failures:
                    result = group_result
                    return result

                stats.full_group_retries += 1
                print(f"Group {group_index} failed with exit code {group_result}; retrying group once", flush=True)
                retry_result = run_group(group, args.timeout, swift_command)
                if retry_result == 0:
                    stats.recovered_groups += 1
                    continue
                if retry_result != 124:
                    result = retry_result
                    return result
                group_timed_out = True
                stats.timed_out_groups += 1

            print(f"Group {group_index} timed out; retrying selections one at a time", flush=True)
            retry_result = retry_selections_individually(group, args.timeout, swift_command, stats)
            if retry_result != 0:
                result = retry_result
                return result
            if group_timed_out:
                stats.recovered_groups += 1

        return result
    finally:
        stats.total_seconds = time.monotonic() - total_started
        if "execution_started" in locals():
            stats.execution_seconds = time.monotonic() - execution_started
        if not args.list_only:
            print_timing_summary(stats)
            append_github_summary(stats)


if __name__ == "__main__":
    raise SystemExit(main())
