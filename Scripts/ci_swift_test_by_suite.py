#!/usr/bin/env python3
"""Run SwiftPM tests in suite shards so CI cannot hang inside one aggregate run."""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
from pathlib import Path
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


@dataclass(frozen=True)
class TestProcess:
    pid: int
    parent: int
    session: int
    birth: tuple[int, int]
    zombie: bool = False


if sys.platform == "darwin":
    class ProcBSDInfo(ctypes.Structure):
        # proc_bsdinfo from sys/proc_info.h; ps lstart loses subsecond PID identity.
        _fields_ = [
            (name, ctypes.c_uint32) for name in (
                "flags", "state", "exit_status", "pid", "parent", "uid", "gid",
                "ruid", "rgid", "svuid", "svgid", "reserved",
            )
        ] + [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)] + [
            (name, ctypes.c_uint32) for name in ("files", "group", "jobc", "tdev", "tpgid", "nice")
        ] + [("seconds", ctypes.c_uint64), ("microseconds", ctypes.c_uint64)]

    class ProcUniqueIdentifierInfo(ctypes.Structure):
        # sys/proc_info_private.h: 56-byte API layout, including unused reserved fields.
        _fields_ = [
            ("uuid", ctypes.c_uint8 * 16), ("uniqueid", ctypes.c_uint64),
            ("parent_uniqueid", ctypes.c_uint64), ("pidversion", ctypes.c_int32),
            ("reserved", ctypes.c_uint32), ("reserved2", ctypes.c_uint64), ("reserved3", ctypes.c_uint64),
        ]

    class ProcBSDInfoWithUniqueID(ctypes.Structure):
        _fields_ = [("bsd", ProcBSDInfo), ("unique", ProcUniqueIdentifierInfo)]

    class AuditToken(ctypes.Structure):
        _fields_ = [("val", ctypes.c_uint32 * 8)]

    _libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    _libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    _libproc.proc_pidinfo.restype = ctypes.c_int
    _proc_signal_with_audittoken = getattr(_libproc, "proc_signal_with_audittoken", None)
    if _proc_signal_with_audittoken is not None:
        _proc_signal_with_audittoken.argtypes = [ctypes.POINTER(AuditToken), ctypes.c_int]
        _proc_signal_with_audittoken.restype = ctypes.c_int


def darwin_pidinfo(pid: int, flavor: int, info):
    ctypes.set_errno(0)
    size = _libproc.proc_pidinfo(pid, flavor, 0, ctypes.byref(info), ctypes.sizeof(info))
    if size != ctypes.sizeof(info):
        error = ctypes.get_errno() if size <= 0 else errno.EIO
        raise OSError(error or errno.EIO, f"Cannot read process metadata for PID {pid}")
    return info


def darwin_signal_process(info: TestProcess, sig: signal.Signals) -> None:
    if _proc_signal_with_audittoken is None:
        raise OSError(errno.ENOSYS, "Darwin process cleanup requires proc_signal_with_audittoken")
    try:
        # PROC_PIDT_BSDINFOWITHUNIQID reads birth and generation from one held proc.
        current = darwin_pidinfo(info.pid, 18, ProcBSDInfoWithUniqueID())
    except (FileNotFoundError, ProcessLookupError):
        return
    if current.bsd.pid != info.pid or (current.bsd.seconds, current.bsd.microseconds) != info.birth:
        return
    # Only target PID/pidversion are used; these are not caller credentials. XNU
    # checks the real caller's permissions and binds the signal to this generation.
    token = AuditToken()
    token.val[5], token.val[7] = info.pid, current.unique.pidversion
    error = _proc_signal_with_audittoken(ctypes.byref(token), sig)
    # libproc returns errno directly, not -1/errno. An exec can stale this token;
    # a later cleanup attempt obtains a fresh generation only after matching birth.
    if error and error != errno.ESRCH:
        raise OSError(error, f"Cannot signal process identity for PID {info.pid}")


def test_process(pid: int) -> TestProcess | None:
    try:
        if sys.platform == "darwin":
            info = darwin_pidinfo(pid, 3, ProcBSDInfo())
            zombie = info.state == 5
            try:
                session = 0 if zombie else os.getsid(pid)
            except ProcessLookupError:
                # getsid excludes exited processes; retain the birth read before that race.
                session = 0
            return TestProcess(pid, info.parent, session, (info.seconds, info.microseconds), zombie)
        if sys.platform.startswith("linux"):
            fields = Path(f"/proc/{pid}/stat").read_bytes().rsplit(b")", 1)[1].split()
            # A zombie leader can still have live threads after pthread_exit(). Linux release_task
            # removes the last nonleader before notifying the parent that the group has exited.
            zombie = fields[0] == b"Z" and int(fields[17]) == 1
            return TestProcess(pid, int(fields[1]), int(fields[3]), (int(fields[19]), 0), zombie)
        raise RuntimeError("Swift test process containment requires macOS or Linux")
    except (FileNotFoundError, ProcessLookupError):
        return None
    except (IndexError, ValueError) as error:
        raise OSError(errno.EIO, f"Incomplete process metadata for PID {pid}") from error


def test_process_snapshot(required: Iterable[int] = ()) -> dict[int, TestProcess]:
    # Numeric metadata only; never inspect command lines or environments of peer jobs.
    pids = subprocess.check_output(["ps", "-axo", "pid="], text=True, timeout=2).split()
    required = set(required)
    snapshot = {}
    for pid in {int(pid) for pid in pids} | required:
        try:
            info = test_process(pid)
        except OSError:
            if pid in required:
                raise
            continue
        if info is not None:
            snapshot[pid] = info
    return snapshot


class TestProcessOwnership:
    def __init__(self, root: TestProcess, process: subprocess.Popen | None = None):
        self.root = root
        self.process = process
        self.known = {root.pid: root.birth}
        self.sessions = {root.pid: root.birth} if root.session == root.pid else {}

    def refresh(self) -> dict[int, TestProcess]:
        snapshot = test_process_snapshot(self.known.keys() | self.sessions.keys())
        if self.process is not None:
            if self.process.returncode is not None:
                raise RuntimeError("Test root was reaped before cleanup completed")
            exited = unreaped_exit_code(self.process) is not None
            current_root = snapshot.get(self.root.pid)
            if current_root is not None and self.root.birth == (0, 0):
                self.root = TestProcess(
                    current_root.pid, current_root.parent, self.process.pid, current_root.birth, current_root.zombie)
                self.known[self.root.pid] = current_root.birth
                self.sessions[self.root.pid] = current_root.birth
            elif current_root is not None and current_root.birth != self.root.birth:
                raise RuntimeError("Test root identity changed before cleanup completed")
            # Darwin can hide metadata before exit becomes waitable. The unreaped child
            # still anchors its PID/session; only wait status establishes root completion.
            snapshot[self.root.pid] = TestProcess(
                self.root.pid, self.root.parent, self.root.session, self.root.birth, exited)
        owned = {pid: info for pid, info in snapshot.items() if self.known.get(pid) == info.birth}
        checked_sessions = {}
        while True:
            self.known.update({pid: info.birth for pid, info in owned.items()})
            self.sessions.update({pid: info.birth for pid, info in owned.items() if info.session == pid})
            for sid, birth in self.sessions.items():
                if sid in checked_sessions:
                    continue
                if self.process is not None and sid == self.root.pid:
                    checked_sessions[sid] = True
                    continue
                anchor = snapshot.get(sid)
                # Recheck AFTER enumeration: the leader might have been reaped during the snapshot.
                current = test_process(sid) if anchor is not None and anchor.birth == birth else None
                checked_sessions[sid] = current is not None and current.birth == birth
            additions = {
                pid: info for pid, info in snapshot.items()
                if pid not in owned and (
                    (info.parent in owned and info.birth >= owned[info.parent].birth)
                    or (checked_sessions.get(info.session, False) and info.birth >= self.sessions[info.session])
                )
            }
            if not additions:
                break
            owned.update(additions)
        for sid in list(self.sessions):
            if checked_sessions[sid]:
                continue
            members = {pid for pid, info in snapshot.items() if info.session == sid and not info.zombie}
            if members - owned.keys():
                raise RuntimeError(
                    f"Lost test session continuity for SID {sid}; "
                    f"cannot attribute PIDs {sorted(members - owned.keys())}")
            if not members:
                del self.sessions[sid]
        # Confirmed exits/replacements retire; unavailable known metadata raises before reaching here.
        self.known = {pid: info.birth for pid, info in owned.items()}
        return {pid: info for pid, info in owned.items() if not info.zombie}

    def send(self, info: TestProcess, sig: signal.Signals) -> None:
        descriptor = None
        try:
            if self.process is not None and info.pid == self.process.pid:
                if self.process.returncode is not None:
                    raise RuntimeError("Test root was reaped before cleanup completed")
                # Direct-child signal authority comes from wait ownership, not metadata
                # which may already be hidden (or a placeholder for an unobserved birth).
                if unreaped_exit_code(self.process) is None:
                    os.kill(self.process.pid, sig)
                return
            if sys.platform.startswith("linux") and hasattr(os, "pidfd_open"):
                descriptor = os.pidfd_open(info.pid)
            current = test_process(info.pid)
            if current is None or current.birth != self.known.get(info.pid) or current.birth != info.birth:
                return
            if descriptor is not None:
                signal.pidfd_send_signal(descriptor, sig)
            elif sys.platform == "darwin":
                darwin_signal_process(info, sig)
            else:
                os.kill(info.pid, sig)
        except ProcessLookupError:
            pass
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def drain(self, process: subprocess.Popen) -> None:
        try:
            self._drain(process)
        except BaseException:
            # If enumeration fails, still stop identities already proven ours, then fail closed.
            for pid, birth in self.known.items():
                try:
                    info = test_process(pid)
                    if info is not None and info.birth == birth:
                        self.send(info, signal.SIGKILL)
                except OSError as error:
                    print(f"Cannot verify cleanup PID {pid}: errno={error.errno}", file=sys.stderr, flush=True)
            try:
                stop_unreaped_child(process)
            except (OSError, subprocess.TimeoutExpired) as error:
                print(f"Direct child cleanup failed: {type(error).__name__}", file=sys.stderr, flush=True)
            raise

    def _drain(self, process: subprocess.Popen) -> None:
        started = time.monotonic()
        terminated: set[tuple[int, tuple[int, int]]] = set()
        while True:
            owned = self.refresh()
            if not owned:
                process.wait(timeout=1)
                return
            elapsed = time.monotonic() - started
            if elapsed >= 5:
                # Never begin a retry while a known child is still running.
                raise RuntimeError(f"Could not drain owned test processes within 5s: {sorted(owned)}")
            for info in owned.values():
                identity = (info.pid, info.birth)
                if elapsed >= 3:
                    self.send(info, signal.SIGKILL)
                elif identity not in terminated:
                    self.send(info, signal.SIGTERM)
                    terminated.add(identity)
            time.sleep(0.1)


def unreaped_exit_code(process: subprocess.Popen) -> int | None:
    result = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    if result is None:
        return None
    return result.si_status if result.si_code == os.CLD_EXITED else -result.si_status


def stop_unreaped_child(process: subprocess.Popen) -> None:
    # The direct child is ours even if native metadata initialization failed. Do not use
    # Popen.terminate/poll: they may reap it and permit its PID/session to be recycled.
    if process.returncode is not None:
        return
    if unreaped_exit_code(process) is not None:
        process.wait(timeout=2)
        return
    try:
        os.kill(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + 3
    while unreaped_exit_code(process) is None and time.monotonic() < deadline:
        time.sleep(0.1)
    if unreaped_exit_code(process) is None:
        try:
            os.kill(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait(timeout=2)


def run_command(command: list[str], timeout: int | None = None) -> int:
    if sys.platform != "darwin" and not sys.platform.startswith("linux"):
        raise RuntimeError("Swift test process containment requires macOS or Linux")
    if not all(hasattr(os, name) for name in ("waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT")):
        raise RuntimeError("Swift test process containment requires waitid with WNOWAIT")
    print(f"+ {' '.join(command)}", flush=True)
    started = time.monotonic()
    ownership = None
    process = None
    try:
        process = subprocess.Popen(command, start_new_session=True)
        root = test_process(process.pid)
        if root is None:
            exited = unreaped_exit_code(process) is not None
            # Missing metadata can precede a waitable exit. Zero is only a placeholder
            # for this unreaped handle; ordinary polling retains the existing deadline.
            root = TestProcess(process.pid, os.getpid(), process.pid, (0, 0), exited)
        # Popen established this session even if getsid now races with the command's exit.
        root = TestProcess(root.pid, root.parent, process.pid, root.birth, root.zombie)
        ownership = TestProcessOwnership(root, process)
        next_diagnostic = started + 30
        while True:
            owned = ownership.refresh()
            result = unreaped_exit_code(process)
            if result is not None:
                return result
            now = time.monotonic()
            if timeout is not None and now - started >= timeout:
                print(f"::warning::Command timed out after {timeout}s: {' '.join(command)}", flush=True)
                return 124
            if now >= next_diagnostic:
                print(f"Swift test command pid={process.pid} elapsed={now - started:.1f}s owned={sorted(owned)}", flush=True)
                next_diagnostic = now + 30
            wait = 0.5 if timeout is None else min(0.5, max(0, timeout - (now - started)))
            time.sleep(wait)
    finally:
        # SwiftPM children can create their own groups; killing only the root group leaks them.
        propagating_error = sys.exc_info()[0] is not None
        previous_interrupt = signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            if process is None:
                pass
            elif ownership is None:
                stop_unreaped_child(process)
            else:
                ownership.drain(process)
        except BaseException as error:
            if not propagating_error:
                raise
            print(f"Cleanup also failed: {type(error).__name__}: {error}", file=sys.stderr, flush=True)
        finally:
            signal.signal(signal.SIGINT, previous_interrupt)


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
