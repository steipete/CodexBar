#!/usr/bin/env python3
"""Synthetic process ownership tests; never launch Swift or inspect provider data."""

import ctypes
import errno
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

import ci_swift_test_by_suite as runner


def running(pid: int) -> bool:
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True, timeout=2
    )
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")


def wait_until(predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError("condition did not become true within its bound")
        time.sleep(0.05)


def publish_fixture_identity(root):
    info = runner.test_process(os.getpid())
    assert info is not None
    (root / "pid").write_text(str(info.pid))
    ready = root / "ready.tmp"
    ready.write_text(json.dumps(dict(pid=info.pid, birth=info.birth)))
    ready.replace(root / "ready")


def release_observed_fixture(root, owned, include_grandchild=False):
    paths = [root, root / "grandchild"] if include_grandchild else [root]
    for path in paths:
        try:
            identity = json.loads((path / "ready").read_text())
        except FileNotFoundError:
            return False
        info = owned.get(identity["pid"])
        if info is None or info.birth != tuple(identity["birth"]):
            return False
    (root / "observed").touch()
    return True


def fixture(mode, directory, ready_delay=0):
    root = Path(directory)
    if mode == "session-leader":
        publish_fixture_identity(root)
        grandchild = root / "grandchild"
        grandchild.mkdir()
        subprocess.Popen([sys.executable, __file__, "--fixture", "child", str(grandchild)])
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not (root / "stop").exists():
            time.sleep(0.05)
        (grandchild / "stop").touch()
        return
    if mode in ("child", "stubborn", "sentinel"):
        if os.getpgrp() != os.getpid():
            os.setpgid(0, 0)
        if mode == "stubborn":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        publish_fixture_identity(root)
        # Self-expiry and the stop file also contain pre-fix failures without fuzzy process kills.
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not (root / "stop").exists():
            time.sleep(0.05)
        return

    child_mode = "stubborn" if mode == "timeout-stubborn" else "child"
    if mode == "success-session-tree":
        child_mode = "session-leader"
    (root / "parent-pid").write_text(str(os.getpid()))
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    if ready_delay:
        ready_at = time.monotonic() + ready_delay
        wait_until(lambda: time.monotonic() >= ready_at or (root / "stop").exists())
        if (root / "stop").exists():
            return
    subprocess.Popen(
        [sys.executable, __file__, "--fixture", child_mode, str(root)],
        start_new_session=mode in ("timeout-session", "success-session", "success-session-tree"),
    )
    # Preserve ancestry until the real ownership refresh has observed the ready identities.
    wait_until(lambda: (root / "observed").exists() or (root / "stop").exists())
    if (root / "stop").exists():
        return
    if mode in ("success", "success-session", "success-session-tree"):
        return
    if mode == "failure":
        raise SystemExit(23)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline and not (root / "stop").exists():
        time.sleep(0.05)


class ProcessCleanupTests(unittest.TestCase):
    def exercise(self, mode, expected, interrupt=False, ready_delay=0):
        with tempfile.TemporaryDirectory(prefix="codexbar-process-cleanup-") as directory:
            root = Path(directory)
            child_root = root / "child"
            sentinel_root = root / "sentinel"
            child_root.mkdir()
            sentinel_root.mkdir()
            sentinel = subprocess.Popen(
                [sys.executable, __file__, "--fixture", "sentinel", str(sentinel_root)],
                start_new_session=True,
            )
            timer = None
            try:
                wait_until(lambda: (sentinel_root / "pid").exists())
                if interrupt:
                    timer = threading.Timer(2, lambda: os.kill(os.getpid(), signal.SIGINT))
                    timer.start()
                started = time.monotonic()
                command = [sys.executable, __file__, "--fixture", mode, str(child_root), str(ready_delay)]
                original_refresh = runner.TestProcessOwnership.refresh
                original_drain = runner.TestProcessOwnership.drain
                acknowledged = False
                draining = False
                def refresh(ownership):
                    nonlocal acknowledged
                    owned = original_refresh(ownership)
                    if not acknowledged and not draining:
                        acknowledged = release_observed_fixture(
                            child_root, owned, include_grandchild=mode == "success-session-tree")
                    return owned
                def drain(ownership, process):
                    nonlocal draining
                    draining = True
                    try:
                        self.assertIsNone(process.returncode, "root was reaped before cleanup")
                        first = runner.unreaped_exit_code(process)
                        if expected in (0, 23):
                            self.assertEqual(first, expected, "fixture must exit before drain begins")
                        if first is not None:
                            self.assertEqual(runner.unreaped_exit_code(process), first)
                        else:
                            info = runner.test_process(process.pid)
                            if info is not None:
                                self.assertEqual(info.birth, ownership.root.birth)
                    finally:
                        original_drain(ownership, process)
                    self.assertIsNotNone(process.returncode, "root was not reaped after cleanup")
                with patch.object(runner.TestProcessOwnership, "refresh", refresh), \
                        patch.object(runner.TestProcessOwnership, "drain", drain):
                    if interrupt:
                        with self.assertRaises(KeyboardInterrupt):
                            runner.run_command(command, timeout=8)
                    else:
                        self.assertEqual(runner.run_command(command, timeout=2), expected)
                elapsed = time.monotonic() - started
                self.assertTrue(acknowledged, "fixture identities were not observed before drain")
                child = int((child_root / "pid").read_text())
                self.assertFalse(running(child), f"owned child {child} survived command completion")
                for pid_file in child_root.rglob("pid"):
                    self.assertFalse(running(int(pid_file.read_text())), f"owned helper {pid_file} survived")
                self.assertFalse(running(int((child_root / "parent-pid").read_text())))
                self.assertIsNone(sentinel.poll(), "unrelated sentinel was terminated")
                self.assertLess(elapsed, 9, "cleanup exceeded bounded grace")
                print(json.dumps(dict(mode=mode, ready_delay=ready_delay, elapsed=round(elapsed, 3),
                                      observed_before_drain=acknowledged, child_terminated=True,
                                      unrelated_sentinel_alive=True)), flush=True)
            finally:
                if timer is not None:
                    timer.cancel()
                    timer.join()
                (child_root / "stop").touch()
                for pid_file in child_root.rglob("pid"):
                    (pid_file.parent / "stop").touch()
                (sentinel_root / "stop").touch()
                sentinel.wait(timeout=3)
                for pid_file in child_root.rglob("pid"):
                    child = int(pid_file.read_text())
                    wait_until(lambda: not running(child))
                if (child_root / "parent-pid").exists():
                    parent = int((child_root / "parent-pid").read_text())
                    wait_until(lambda: not running(parent))

    def test_timeout_drains_separate_child_group_after_parent_exits_on_term(self):
        self.exercise("timeout", 124)

    def test_timeout_escalates_for_term_ignoring_child(self):
        self.exercise("timeout-stubborn", 124)

    def test_timeout_retains_observed_child_after_it_starts_a_separate_session(self):
        self.exercise("timeout-session", 124)

    def test_success_drains_lingering_child_without_touching_sentinel(self):
        self.exercise("success", 0)

    def test_success_after_delayed_readiness_keeps_the_two_second_budget(self):
        # One second of startup plus the former 1.2-second ancestry sleep exceeds the command budget.
        self.exercise("success", 0, ready_delay=1)

    def test_success_allows_and_drains_a_separate_session(self):
        self.exercise("success-session", 0)

    def test_success_drains_observed_child_session_and_its_grandchild(self):
        self.exercise("success-session-tree", 0)

    def test_signal_exit_status_is_preserved(self):
        self.assertEqual(runner.run_command(["/bin/sh", "-c", "kill -TERM $$"], timeout=2), -signal.SIGTERM)

    def test_failure_drains_lingering_child_and_preserves_exit_code(self):
        self.exercise("failure", 23)

    def test_keyboard_interrupt_drains_children_and_propagates(self):
        self.exercise("timeout", None, interrupt=True)


class ProcessIdentityTests(unittest.TestCase):
    def test_native_identity_matches_own_parent_and_session(self):
        info = runner.test_process(os.getpid())
        self.assertIsNotNone(info)
        self.assertEqual(info.parent, os.getppid())
        self.assertEqual(info.session, os.getsid(0))
        self.assertGreater(info.birth[0], 0)

    def test_reparenting_preserves_observed_child_ownership(self):
        root = runner.TestProcess(10, 1, 10, (100, 0))
        child = runner.TestProcess(20, 10, 20, (101, 0))
        orphan = runner.TestProcess(20, 1, 20, child.birth)
        peer = runner.TestProcess(30, 1, 30, (102, 0))
        ownership = runner.TestProcessOwnership(root)
        with patch.object(runner, "test_process_snapshot", side_effect=[{10: root, 20: child}, {20: orphan, 30: peer}]):
            self.assertEqual(set(ownership.refresh()), {10, 20})
            self.assertEqual(set(ownership.refresh()), {20})

    def test_root_pid_reuse_does_not_claim_the_new_session(self):
        root = runner.TestProcess(10, 1, 10, (100, 0))
        replacement = runner.TestProcess(10, 1, 10, (200, 0))
        peer = runner.TestProcess(30, 10, 10, (201, 0))
        ownership = runner.TestProcessOwnership(root)
        with patch.object(runner, "test_process_snapshot", return_value={10: replacement, 30: peer}):
            with self.assertRaisesRegex(RuntimeError, "session continuity"):
                ownership.refresh()
        self.assertNotIn(30, ownership.known)

    def test_stale_parent_pid_does_not_claim_a_process_older_than_its_parent(self):
        root = runner.TestProcess(10, 1, 10, (100, 0))
        stale = runner.TestProcess(20, 10, 20, (99, 0))
        ownership = runner.TestProcessOwnership(root)
        with patch.object(runner, "test_process_snapshot", return_value={10: root, 20: stale}):
            self.assertEqual(set(ownership.refresh()), {10})

    def test_pid_reuse_is_rechecked_immediately_before_signal(self):
        root = runner.TestProcess(10, 1, 10, (100, 0))
        replacement = runner.TestProcess(10, 1, 10, (200, 0))
        ownership = runner.TestProcessOwnership(root)
        with patch.object(runner, "test_process", return_value=replacement), \
                patch.object(runner.sys, "platform", "darwin"), patch.object(runner.os, "kill") as kill:
            ownership.send(root, signal.SIGTERM)
        kill.assert_not_called()

    def test_linux_stat_parser_preserves_birth_ticks_with_parentheses_in_command(self):
        fields = ["S", "11", "123", "123", *(["0"] * 15), "456", "0"]
        with patch.object(runner.sys, "platform", "linux"), \
                patch.object(runner.Path, "read_bytes", return_value=("123 (tool ) name) " + " ".join(fields)).encode()):
            self.assertEqual(runner.test_process(123), runner.TestProcess(123, 11, 123, (456, 0)))

    def test_linux_signals_the_pinned_identity(self):
        root = runner.TestProcess(10, 1, 10, (100, 0))
        ownership = runner.TestProcessOwnership(root)
        with patch.object(runner, "test_process", return_value=root), \
                patch.object(runner.sys, "platform", "linux"), \
                patch.object(runner.os, "pidfd_open", return_value=77, create=True), \
                patch.object(runner.signal, "pidfd_send_signal", create=True) as send, \
                patch.object(runner.os, "close") as close, patch.object(runner.os, "kill") as kill:
            ownership.send(root, signal.SIGTERM)
        send.assert_called_once_with(77, signal.SIGTERM)
        close.assert_called_once_with(77)
        kill.assert_not_called()

    def test_undrained_child_fails_closed_after_bounded_grace(self):
        root = runner.TestProcess(10, 1, 10, (100, 0))
        ownership = runner.TestProcessOwnership(root)
        process = Mock()
        with patch.object(ownership, "refresh", return_value={10: root}), \
                patch.object(ownership, "send") as send, \
                patch.object(runner, "stop_unreaped_child") as stop, \
                patch.object(runner.time, "monotonic", side_effect=[0, 0, 3.1, 5.1]), \
                patch.object(runner.time, "sleep"):
            with self.assertRaisesRegex(RuntimeError, "Could not drain"):
                ownership.drain(process)
        self.assertEqual([call.args[1] for call in send.call_args_list], [signal.SIGTERM, signal.SIGKILL])
        stop.assert_called_once_with(process)

    def test_enumeration_failure_stops_known_identities_and_does_not_report_success(self):
        root = runner.TestProcess(10, 1, 10, (100, 0))
        ownership = runner.TestProcessOwnership(root)
        process = Mock()
        with patch.object(ownership, "refresh", side_effect=OSError("enumeration unavailable")), \
                patch.object(runner, "test_process", return_value=root), patch.object(ownership, "send") as send, \
                patch.object(runner, "stop_unreaped_child") as stop:
            with self.assertRaisesRegex(OSError, "enumeration unavailable"):
                ownership.drain(process)
        send.assert_called_once_with(root, signal.SIGKILL)
        stop.assert_called_once_with(process)


@unittest.skipUnless(sys.platform == "darwin", "requires Darwin audit-token signaling")
class DarwinSignalTests(unittest.TestCase):
    child = runner.TestProcess(20, 10, 20, (101, 123))

    def setUp(self):
        self.ownership = runner.TestProcessOwnership(runner.TestProcess(10, 1, 10, (100, 0)))
        self.ownership.known[self.child.pid] = self.child.birth
        self.generation = 41

    def metadata(self, pid, flavor, offset, pointer, size):
        self.assertEqual((pid, flavor, offset, size), (20, 18, 0, 192))
        info = pointer._obj
        info.bsd.pid, info.bsd.parent = pid, self.child.parent
        info.bsd.seconds, info.bsd.microseconds = self.child.birth
        info.unique.pidversion = self.generation
        return size

    def send_with_native(self, native, metadata=None):
        # Fake PIDs never reach any real signal API, including the pre-fix numeric path.
        with patch.object(runner, "test_process", return_value=self.child), \
                patch.object(runner._libproc, "proc_pidinfo", side_effect=metadata or self.metadata), \
                patch.object(runner, "_proc_signal_with_audittoken", native, create=True), \
                patch.object(runner.os, "kill") as kill:
            try:
                self.ownership.send(self.child, signal.SIGTERM)
            finally:
                kill.assert_not_called()

    def test_generation_change_between_metadata_and_signal_never_signals_replacement(self):
        delivered = []
        captured = []
        def native(pointer, sig):
            token = pointer._obj
            captured.append((token.val[5], token.val[7], sig))
            self.generation += 1  # deterministic replacement after the combined read
            if token.val[7] != self.generation:
                return errno.ESRCH
            delivered.append(token.val[5])
            return 0
        self.send_with_native(native)
        self.assertEqual(captured, [(20, 41, signal.SIGTERM)])
        self.assertEqual(delivered, [])

    def test_same_birth_exec_refreshes_generation_on_later_attempt(self):
        tokens = []
        def native(pointer, sig):
            tokens.append(pointer._obj.val[7])
            if len(tokens) == 1:
                self.generation += 1
                return errno.ESRCH
            return 0
        self.send_with_native(native)
        self.send_with_native(native)
        self.assertEqual(tokens, [41, 42])

    def test_success_uses_return_value_not_stale_errno_or_numeric_pid(self):
        def native(pointer, sig):
            self.assertEqual(list(pointer._obj.val), [0, 0, 0, 0, 0, 20, 0, 41])
            ctypes.set_errno(errno.EPERM)
            return 0
        send = Mock(side_effect=native)
        self.send_with_native(send)
        send.assert_called_once()

    def test_native_errno_is_preserved_without_numeric_fallback(self):
        for error in (errno.EPERM, errno.EACCES, errno.EIO, errno.EINVAL, errno.ENOSYS, errno.ENOENT):
            with self.subTest(errno=error):
                ctypes.set_errno(errno.ESRCH)
                with self.assertRaises(OSError) as raised:
                    self.send_with_native(Mock(return_value=error))
                self.assertEqual(raised.exception.errno, error)

    def test_missing_native_api_fails_closed(self):
        with self.assertRaises(OSError) as raised:
            self.send_with_native(None)
        self.assertEqual(raised.exception.errno, errno.ENOSYS)

    def test_combined_birth_mismatch_never_sends(self):
        def metadata(*args):
            size = self.metadata(*args)
            args[3]._obj.bsd.microseconds += 1
            return size
        send = Mock(return_value=0)
        self.send_with_native(send, metadata)
        send.assert_not_called()

    def test_combined_metadata_errors_do_not_become_success(self):
        for error in (errno.ESRCH, errno.ENOENT, errno.EPERM, errno.EACCES, errno.EIO, errno.EINVAL, 0):
            def metadata(*_):
                ctypes.set_errno(error)
                return 0
            send = Mock(return_value=0)
            with self.subTest(errno=error):
                if error in (errno.ESRCH, errno.ENOENT):
                    self.send_with_native(send, metadata)
                else:
                    with self.assertRaises(OSError) as raised:
                        self.send_with_native(send, metadata)
                    self.assertEqual(raised.exception.errno, error or errno.EIO)
                send.assert_not_called()

    def test_partial_combined_metadata_is_io_error_even_with_stale_esrch(self):
        def metadata(*_):
            ctypes.set_errno(errno.ESRCH)
            return 136
        with self.assertRaises(OSError) as raised:
            self.send_with_native(Mock(return_value=0), metadata)
        self.assertEqual(raised.exception.errno, errno.EIO)


@unittest.skipUnless(sys.platform == "darwin", "requires native Darwin audit-token signaling")
class DarwinNativeSignalTests(unittest.TestCase):
    def exercise(self, sig):
        self.assertEqual(ctypes.sizeof(runner.ProcBSDInfo), 136)
        self.assertEqual(ctypes.sizeof(runner.ProcUniqueIdentifierInfo), 56)
        self.assertEqual(runner.ProcUniqueIdentifierInfo.pidversion.offset, 32)
        self.assertEqual(runner.ProcBSDInfoWithUniqueID.unique.offset, 136)
        self.assertEqual(ctypes.sizeof(runner.ProcBSDInfoWithUniqueID), 192)
        self.assertEqual(ctypes.sizeof(runner.AuditToken), 32)
        native = runner._proc_signal_with_audittoken
        self.assertIsNotNone(native, "native signal API must be available on supported macOS")
        with tempfile.TemporaryDirectory(prefix="codexbar-audit-signal-") as directory:
            root = Path(directory)
            processes = []
            def start(name, mode):
                path = root / name
                path.mkdir()
                process = subprocess.Popen([sys.executable, __file__, "--fixture", mode, str(path)],
                                           start_new_session=True)
                processes.append(process)
                wait_until(lambda: (path / "pid").exists())
                return process
            def identity(pid):
                info = runner.darwin_pidinfo(pid, 18, runner.ProcBSDInfoWithUniqueID())
                return (info.bsd.pid, info.bsd.parent, info.bsd.seconds, info.bsd.microseconds,
                        info.unique.pidversion & 0xFFFFFFFF)
            try:
                sentinel = start("sentinel", "sentinel")
                child = start("child", "child" if sig == signal.SIGTERM else "stubborn")
                before, sentinel_before = identity(child.pid), identity(sentinel.pid)
                tracked = runner.test_process(child.pid)
                self.assertEqual(before[:4], (child.pid, os.getpid(), *tracked.birth))
                ownership = runner.TestProcessOwnership(runner.test_process(os.getpid()))
                ownership.known[child.pid] = tracked.birth
                wrong = runner.AuditToken()
                wrong.val[5], wrong.val[7] = child.pid, before[4] ^ 1
                wrong_result = native(ctypes.byref(wrong), sig)
                self.assertEqual(wrong_result, errno.ESRCH)
                time.sleep(0.1)
                after_wrong = identity(child.pid)
                self.assertEqual(after_wrong, before)
                self.assertIsNone(runner.unreaped_exit_code(child), "wrong generation signaled the live fixture")
                self.assertIsNone(child.returncode, "fixture must remain wait-owned until matching signal")
                results = []
                def matching(pointer, requested):
                    self.assertEqual((pointer._obj.val[5], pointer._obj.val[7], requested),
                                     (child.pid, before[4], sig))
                    result = native(pointer, requested)
                    results.append(result)
                    return result
                with patch.object(runner, "_proc_signal_with_audittoken", side_effect=matching), \
                        patch.object(runner.os, "kill") as kill:
                    ownership.send(tracked, sig)
                    kill.assert_not_called()
                self.assertEqual(results, [0])
                self.assertEqual(child.wait(timeout=3), -sig)
                self.assertEqual(identity(sentinel.pid), sentinel_before)
                self.assertIsNone(runner.unreaped_exit_code(sentinel), "unrelated sentinel was signaled")
                print(json.dumps(dict(signal=sig.name, before=before, after_wrong=after_wrong,
                                      wrong_pidversion=wrong.val[7], wrong_result=wrong_result,
                                      matching_results=results, reaped_status=child.returncode,
                                      unrelated_sentinel_alive=True)), flush=True)
            finally:
                for path in root.iterdir():
                    (path / "stop").touch()
                for process in processes:
                    runner.stop_unreaped_child(process)

    def test_wrong_generation_survives_then_matching_identity_terms_and_reaps(self):
        self.exercise(signal.SIGTERM)

    def test_wrong_generation_survives_then_matching_identity_kills_and_reaps(self):
        self.exercise(signal.SIGKILL)


class ReviewRegressionTests(unittest.TestCase):
    def test_recycled_sid_without_replacement_leader_is_not_adopted(self):
        root = runner.TestProcess(10, 1, 10, (100, 0))
        peer = runner.TestProcess(30, 1, 10, (201, 0))
        ownership = runner.TestProcessOwnership(root)
        with patch.object(runner, "test_process_snapshot", return_value={30: peer}):
            with self.assertRaisesRegex(RuntimeError, "session continuity"):
                ownership.refresh()
        self.assertNotIn(30, ownership.known)

    @unittest.skipUnless(sys.platform == "darwin", "Darwin native race regression")
    def test_darwin_getsid_exit_race_preserves_birth(self):
        def live_info(pid, flavor, offset, pointer, size):
            info = pointer._obj
            info.pid, info.parent, info.state = pid, 11, 2
            info.seconds, info.microseconds = 456, 789
            return size
        with patch.object(runner._libproc, "proc_pidinfo", side_effect=live_info), \
                patch.object(runner.os, "getsid", side_effect=ProcessLookupError(errno.ESRCH, "exited")):
            info = runner.test_process(123)
        self.assertIsNotNone(info)
        self.assertEqual(info.birth, (456, 789))

    def test_known_unreadable_linux_metadata_fails_snapshot_but_unrelated_peer_does_not(self):
        root = runner.TestProcess(10, 1, 10, (100, 0))
        fields = b"10 (root) S 1 10 10 " + b"0 " * 15 + b"100 0"
        def read(path):
            if str(path) == "/proc/10/stat":
                return fields
            raise PermissionError(errno.EACCES, "denied")
        ownership = runner.TestProcessOwnership(root)
        with patch.object(runner.sys, "platform", "linux"), \
                patch.object(runner.subprocess, "check_output", return_value="10 20"), \
                patch.object(runner.Path, "read_bytes", autospec=True, side_effect=read):
            self.assertEqual(set(ownership.refresh()), {10})
            ownership.known[20] = (101, 0)
            with self.assertRaises(PermissionError):
                ownership.refresh()

    @unittest.skipUnless(sys.platform == "darwin", "Darwin native error regression")
    def test_known_unreadable_darwin_metadata_fails_snapshot_but_unrelated_peer_does_not(self):
        def denied(*_):
            ctypes.set_errno(errno.EPERM)
            return 0
        with patch.object(runner._libproc, "proc_pidinfo", side_effect=denied), \
                patch.object(runner.subprocess, "check_output", return_value="123"):
            self.assertEqual(runner.test_process_snapshot(), {})
            with self.assertRaises(PermissionError):
                runner.TestProcessOwnership(runner.TestProcess(123, 1, 123, (100, 0))).refresh()

    def test_linux_metadata_permission_failure_is_not_exit(self):
        with patch.object(runner.sys, "platform", "linux"), \
                patch.object(runner.Path, "read_bytes", side_effect=PermissionError(errno.EACCES, "denied")), \
                patch.object(runner.Path, "read_text", side_effect=PermissionError(errno.EACCES, "denied")):
            with self.assertRaises(PermissionError):
                runner.test_process(123)

    def test_linux_stat_does_not_decode_invalid_command_bytes(self):
        fields = [b"S", b"11", b"123", b"123", *([b"0"] * 15), b"456", b"0"]
        raw = b"123 (tool ) \xff\xe2) " + b" ".join(fields)
        with patch.object(runner.sys, "platform", "linux"), \
                patch.object(runner.Path, "read_bytes", return_value=raw), \
                patch.object(runner.Path, "read_text", side_effect=UnicodeDecodeError("utf8", b"\xff", 0, 1, "invalid")):
            self.assertEqual(runner.test_process(123).birth, (456, 0))

    def test_linux_zombie_leader_with_other_threads_is_not_dead(self):
        fields = [b"Z", b"11", b"123", b"123", *([b"0"] * 15), b"456", b"0"]
        fields[17] = b"2"
        raw = b"123 (worker) " + b" ".join(fields)
        with patch.object(runner.sys, "platform", "linux"), \
                patch.object(runner.Path, "read_bytes", return_value=raw), \
                patch.object(runner.Path, "read_text", return_value=raw.decode()):
            self.assertFalse(runner.test_process(123).zombie)

    def test_linux_zombie_leader_is_dead_only_after_last_thread_exits(self):
        fields = [b"Z", b"11", b"123", b"123", *([b"0"] * 15), b"456", b"0"]
        fields[17] = b"1"
        with patch.object(runner.sys, "platform", "linux"), \
                patch.object(runner.Path, "read_bytes", return_value=b"123 (worker) " + b" ".join(fields)):
            self.assertTrue(runner.test_process(123).zombie)

    def test_linux_confirmed_exit_is_absence_but_truncated_stat_is_uncertain(self):
        with patch.object(runner.sys, "platform", "linux"):
            with patch.object(runner.Path, "read_bytes", side_effect=FileNotFoundError(errno.ENOENT, "exited")):
                self.assertIsNone(runner.test_process(123))
            with patch.object(runner.Path, "read_bytes", return_value=b"123 (truncated"):
                with self.assertRaises(OSError) as raised:
                    runner.test_process(123)
                self.assertEqual(raised.exception.errno, errno.EIO)

    def test_known_metadata_failure_still_cleans_readable_identities_and_preserves_error(self):
        ownership = runner.TestProcessOwnership(runner.TestProcess(10, 1, 10, (100, 0)))
        ownership.known[20] = (101, 0)
        failure = PermissionError(errno.EACCES, "known identity unavailable")
        def read(path):
            if str(path) == "/proc/10/stat":
                raise failure
            return b"20 (child) S 10 20 20 " + b"0 " * 15 + b"101 0"
        process = Mock()
        with patch.object(runner.sys, "platform", "linux"), \
                patch.object(runner.subprocess, "check_output", return_value="10 20"), \
                patch.object(runner.Path, "read_bytes", autospec=True, side_effect=read), \
                patch.object(ownership, "send") as send, \
                patch.object(runner, "stop_unreaped_child") as stop:
            with self.assertRaises(PermissionError) as raised:
                ownership.drain(process)
        self.assertIs(raised.exception, failure)
        self.assertEqual([(call.args[0].pid, call.args[1]) for call in send.call_args_list], [(20, signal.SIGKILL)])
        stop.assert_called_once_with(process)

    @unittest.skipUnless(sys.platform == "darwin", "Darwin native error regression")
    def test_darwin_permission_failure_is_not_exit(self):
        def denied(*_):
            ctypes.set_errno(errno.EPERM)
            return 0
        with patch.object(runner._libproc, "proc_pidinfo", side_effect=denied):
            with self.assertRaises(OSError):
                runner.test_process(123)

    @unittest.skipUnless(sys.platform == "darwin", "Darwin native error regression")
    def test_darwin_only_confirmed_exit_is_absence(self):
        for error in (errno.ESRCH, errno.ENOENT, errno.EIO, 0):
            def unavailable(*_):
                ctypes.set_errno(error)
                return 0
            with self.subTest(errno=error), patch.object(runner._libproc, "proc_pidinfo", side_effect=unavailable):
                if error in (errno.ESRCH, errno.ENOENT):
                    self.assertIsNone(runner.test_process(123))
                else:
                    with self.assertRaises(OSError):
                        runner.test_process(123)

    def exercise_initialization_failure(self, failure):
        with tempfile.TemporaryDirectory(prefix="codexbar-init-cleanup-") as directory:
            root = Path(directory)
            spawned = []
            original_spawn = subprocess.Popen
            original_lookup = runner.test_process
            def spawn(*args, **kwargs):
                process = original_spawn(*args, **kwargs)
                if args[0][0] == sys.executable:
                    spawned.append(process)
                return process
            first = True
            def lookup(pid, *args, **kwargs):
                nonlocal first
                if first:
                    first = False
                    wait_until(lambda: (root / "pid").exists())
                    if failure is not None:
                        raise failure
                    return None
                if failure is None and spawned and pid == spawned[0].pid:
                    return None
                return original_lookup(pid, *args, **kwargs)
            started = time.monotonic()
            sent = []
            original_kill = os.kill
            def kill(pid, sig):
                if spawned and pid == spawned[0].pid:
                    sent.append((sig, time.monotonic() - started))
                return original_kill(pid, sig)
            try:
                with patch.object(runner.subprocess, "Popen", side_effect=spawn), \
                        patch.object(runner, "test_process", side_effect=lookup), \
                        patch.object(runner.os, "kill", side_effect=kill):
                    if failure is None:
                        self.assertEqual(runner.run_command(
                            [sys.executable, __file__, "--fixture", "stubborn", str(root)], timeout=2), 124)
                    else:
                        with self.assertRaises(type(failure)) as raised:
                            runner.run_command([sys.executable, __file__, "--fixture", "stubborn", str(root)], timeout=2)
                        self.assertIs(raised.exception, failure)
                self.assertEqual(len(spawned), 1)
                self.assertIsNotNone(spawned[0].poll(), "initialization failure leaked direct child")
                if failure is None:
                    self.assertEqual([sig for sig, _ in sent], [signal.SIGTERM, signal.SIGKILL])
                    self.assertGreaterEqual(sent[0][1], 2, "missing metadata shortened the command deadline")
                    self.assertEqual(spawned[0].returncode, -signal.SIGKILL)
                self.assertLess(time.monotonic() - started, 9)
            finally:
                (root / "stop").touch()
                for process in spawned:
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=2)

    def test_initial_metadata_exception_reaps_direct_child(self):
        self.exercise_initialization_failure(PermissionError(errno.EACCES, "injected initialization failure"))

    def test_initial_keyboard_interrupt_reaps_direct_child(self):
        self.exercise_initialization_failure(KeyboardInterrupt())

    def test_initial_missing_metadata_times_out_and_reaps_term_ignoring_child(self):
        self.exercise_initialization_failure(None)


class ExitTransitionTests(unittest.TestCase):
    def exercise_transition(self, initial, result):
        process = Mock(pid=10, returncode=None)
        root = runner.TestProcess(10, 1, 10, (100, 0))
        clock = [0.0]
        sleeps = []
        def sleep(seconds):
            sleeps.append(seconds)
            clock[0] += seconds
        def wait(timeout):
            self.assertGreaterEqual(clock[0], 1, "root was reaped before its exit was waitable")
            process.returncode = result
            return result
        process.wait.side_effect = wait
        lookup = [None if initial else root]
        def metadata(_pid):
            return lookup.pop() if lookup else None
        def waitid(*_args):
            return None if clock[0] < 1 else Mock(si_code=os.CLD_EXITED, si_status=result)
        with patch.object(runner.subprocess, "Popen", return_value=process), \
                patch.object(runner, "test_process", side_effect=metadata), \
                patch.object(runner, "test_process_snapshot", return_value={}), \
                patch.object(runner.os, "waitid", side_effect=waitid), \
                patch.object(runner.os, "kill") as kill, \
                patch.object(runner.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(runner.time, "sleep", side_effect=sleep):
            self.assertEqual(runner.run_command(["synthetic-exit-transition"], timeout=2), result)
        self.assertEqual(sleeps, [0.5, 0.5], "transition must use ordinary polling, without extra grace")
        kill.assert_not_called()
        process.wait.assert_called_once_with(timeout=1)
        self.assertEqual(process.returncode, result)

    def test_initial_missing_metadata_then_pending_wait_then_success(self):
        self.exercise_transition(True, 0)

    def test_initial_missing_metadata_then_pending_wait_then_nonzero_exit(self):
        self.exercise_transition(True, 23)

    def test_later_missing_metadata_then_pending_wait_then_success(self):
        self.exercise_transition(False, 0)

    def test_later_missing_metadata_then_pending_wait_then_nonzero_exit(self):
        self.exercise_transition(False, 23)

    def test_pending_hidden_root_remains_live_and_anchors_orphan_session(self):
        root = runner.TestProcess(10, 1, 10, (100, 0))
        orphan = runner.TestProcess(20, 1, 10, (101, 0))
        ownership = runner.TestProcessOwnership(root, Mock(pid=10, returncode=None))
        with patch.object(runner, "test_process_snapshot", return_value={20: orphan}), \
                patch.object(runner.os, "waitid", return_value=None):
            owned = ownership.refresh()
        self.assertEqual(set(owned), {10, 20})
        self.assertFalse(owned[10].zombie)
        self.assertEqual(owned[10].birth, root.birth)

    def test_hidden_root_signal_requires_wait_ownership_not_placeholder_birth(self):
        root = runner.TestProcess(10, 1, 10, (0, 0))
        ownership = runner.TestProcessOwnership(root, Mock(pid=10, returncode=None))
        with patch.object(runner, "test_process", return_value=None), \
                patch.object(runner.os, "waitid", side_effect=ChildProcessError()), \
                patch.object(runner.os, "kill") as kill:
            with self.assertRaises(ChildProcessError):
                ownership.send(root, signal.SIGKILL)
        kill.assert_not_called()

    def test_permanently_pending_transition_times_out_and_fails_undrained_cleanup(self):
        process = Mock(pid=10, returncode=None)
        clock = [0.0]
        signals = []
        def sleep(seconds):
            clock[0] += seconds
        def wait(timeout):
            clock[0] += timeout
            raise subprocess.TimeoutExpired("synthetic-pending-transition", timeout)
        process.wait.side_effect = wait
        with patch.object(runner.subprocess, "Popen", return_value=process), \
                patch.object(runner, "test_process", return_value=None), \
                patch.object(runner, "test_process_snapshot", return_value={}), \
                patch.object(runner.os, "waitid", return_value=None), \
                patch.object(runner.os, "kill", side_effect=lambda pid, sig: signals.append((pid, sig, clock[0]))), \
                patch.object(runner.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(runner.time, "sleep", side_effect=sleep):
            with self.assertRaisesRegex(RuntimeError, "Could not drain"):
                runner.run_command(["synthetic-pending-transition"], timeout=2)
        self.assertEqual(signals[0], (10, signal.SIGTERM, 2.0))
        self.assertTrue(any(sig == signal.SIGKILL and when >= 5 for _, sig, when in signals))
        self.assertLess(clock[0], 13, "pending transition must not create an unbounded retry")
        self.assertIsNone(process.returncode, "unwaitable root must never be reported reaped")


class AnchorSemanticsTests(unittest.TestCase):
    def test_lost_direct_child_wait_ownership_never_signals_numeric_pid(self):
        process = Mock(pid=10, returncode=None)
        with patch.object(runner.os, "waitid", side_effect=ChildProcessError()), \
                patch.object(runner.os, "kill") as kill:
            with self.assertRaises(ChildProcessError):
                runner.stop_unreaped_child(process)
        kill.assert_not_called()

    def test_exited_root_hidden_from_native_metadata_still_anchors_orphan_session(self):
        root = runner.TestProcess(10, 1, 10, (100, 0))
        orphan = runner.TestProcess(20, 1, 10, (101, 0))
        process = Mock(pid=10, returncode=None)
        ownership = runner.TestProcessOwnership(root, process)
        with patch.object(runner, "test_process_snapshot", return_value={20: orphan}), \
                patch.object(runner, "unreaped_exit_code", return_value=0):
            self.assertEqual(set(ownership.refresh()), {20})

    def test_command_exited_before_initial_native_lookup_preserves_status(self):
        original_lookup = runner.test_process
        spawned = []
        original_spawn = subprocess.Popen
        def spawn(*args, **kwargs):
            process = original_spawn(*args, **kwargs)
            if args[0][0] == "/bin/sh":
                spawned.append(process)
            return process
        def lookup(pid):
            if spawned and pid == spawned[0].pid:
                wait_until(lambda: runner.unreaped_exit_code(spawned[0]) is not None)
                return None
            return original_lookup(pid)
        try:
            with patch.object(runner.subprocess, "Popen", side_effect=spawn), \
                    patch.object(runner, "test_process", side_effect=lookup):
                self.assertEqual(runner.run_command(["/bin/sh", "-c", "exit 23"], timeout=2), 23)
            self.assertEqual(spawned[0].returncode, 23)
        finally:
            for process in spawned:
                runner.stop_unreaped_child(process)

    def test_waitid_observes_exit_repeatedly_without_reaping_session_anchor(self):
        with tempfile.TemporaryDirectory(prefix="codexbar-waitid-anchor-") as directory:
            root = Path(directory)
            process = subprocess.Popen([sys.executable, __file__, "--fixture", "success", directory],
                                       start_new_session=True)
            try:
                wait_until(lambda: (root / "ready").exists())
                self.assertIsNone(runner.unreaped_exit_code(process))
                identity = runner.test_process(process.pid)
                self.assertIsNotNone(identity)
                ownership = runner.TestProcessOwnership(identity, process)
                wait_until(lambda: release_observed_fixture(root, ownership.refresh()))
                options = os.WEXITED | os.WNOHANG | os.WNOWAIT
                wait_until(lambda: os.waitid(os.P_PID, process.pid, options) is not None)
                first = os.waitid(os.P_PID, process.pid, options)
                second = os.waitid(os.P_PID, process.pid, options)
                self.assertEqual(first.si_pid, process.pid)
                self.assertEqual(first.si_status, 0)
                self.assertEqual(first, second)
                self.assertIsNone(process.returncode)
                child = int((root / "pid").read_text())
                self.assertTrue(running(child))
                self.assertEqual(os.getsid(child), process.pid)
                (root / "stop").touch()
                wait_until(lambda: not running(child))
                self.assertEqual(process.wait(timeout=2), 0)
                with self.assertRaises(ChildProcessError):
                    os.waitid(os.P_PID, process.pid, options)
                print("waitid WNOWAIT: repeated exit observation retained anchor and orphan SID until explicit reap", flush=True)
            finally:
                (root / "stop").touch()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
                if (root / "pid").exists():
                    child = int((root / "pid").read_text())
                    wait_until(lambda: not running(child))


class SessionOwnershipTests(unittest.TestCase):
    root = runner.TestProcess(10, 1, 10, (100, 0))
    leader = runner.TestProcess(20, 10, 20, (101, 0))
    helper = runner.TestProcess(30, 1, 20, (102, 0))

    def refresh(self, ownership, *infos):
        snapshot = {info.pid: info for info in infos}
        with patch.object(runner, "test_process_snapshot", return_value=snapshot), \
                patch.object(runner, "test_process", side_effect=snapshot.get):
            return ownership.refresh()

    def test_live_child_session_anchor_adopts_reparented_grandchild(self):
        ownership = runner.TestProcessOwnership(self.root)
        self.refresh(ownership, self.root, self.leader)
        self.assertEqual(set(self.refresh(ownership, self.root, self.leader, self.helper)), {10, 20, 30})
        self.assertEqual(set(self.refresh(ownership, self.root, self.helper)), {10, 30})
        self.assertEqual(set(self.refresh(ownership, self.root)), {10})

    def test_unreaped_child_session_anchor_adopts_reparented_grandchild(self):
        ownership = runner.TestProcessOwnership(self.root)
        self.refresh(ownership, self.root, self.leader)
        zombie = runner.TestProcess(20, 1, 0, self.leader.birth, True)
        self.assertEqual(set(self.refresh(ownership, self.root, zombie, self.helper)), {10, 30})

    def test_lost_child_session_anchor_fails_without_claiming_unknown_member(self):
        ownership = runner.TestProcessOwnership(self.root)
        self.refresh(ownership, self.root, self.leader)
        with self.assertRaisesRegex(RuntimeError, "session continuity"):
            self.refresh(ownership, self.root, self.helper)
        self.assertNotIn(30, ownership.known)

    def test_reused_child_session_anchor_does_not_claim_unrelated_member(self):
        ownership = runner.TestProcessOwnership(self.root)
        self.refresh(ownership, self.root, self.leader)
        replacement = runner.TestProcess(20, 1, 20, (200, 0))
        with self.assertRaisesRegex(RuntimeError, "session continuity"):
            self.refresh(ownership, self.root, replacement, self.helper)
        self.assertEqual(ownership.known[20], self.leader.birth)
        self.assertNotIn(30, ownership.known)

    def test_completed_empty_child_session_retires_without_rejecting_later_peer(self):
        ownership = runner.TestProcessOwnership(self.root)
        self.refresh(ownership, self.root, self.leader)
        self.assertEqual(set(self.refresh(ownership, self.root)), {10})
        self.assertEqual(set(self.refresh(ownership, self.root, self.helper)), {10})

    def test_session_anchor_is_rechecked_after_member_enumeration(self):
        ownership = runner.TestProcessOwnership(self.root)
        self.refresh(ownership, self.root, self.leader)
        snapshot = {10: self.root, 20: self.leader, 30: self.helper}
        with patch.object(runner, "test_process_snapshot", return_value=snapshot), \
                patch.object(runner, "test_process", side_effect=lambda pid: self.root if pid == 10 else None):
            with self.assertRaisesRegex(RuntimeError, "session continuity"):
                ownership.refresh()
        self.assertNotIn(30, ownership.known)


@unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux /proc and pthread_exit semantics")
class LinuxThreadGroupTests(unittest.TestCase):
    def test_native_zombie_leader_with_live_worker_is_killed_and_reaped(self):
        with tempfile.TemporaryDirectory(prefix="codexbar-linux-thread-group-") as directory:
            root = Path(directory)
            source = root / "thread.c"
            binary = root / "thread"
            stop = root / "stop"
            source.write_text(r'''
#include <pthread.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
static void *worker(void *stop) {
    time_t deadline = time(NULL) + 20;
    while (time(NULL) < deadline && access(stop, F_OK) != 0) usleep(10000);
    return NULL;
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    signal(SIGTERM, SIG_IGN);
    pthread_t thread;
    if (pthread_create(&thread, NULL, worker, argv[1])) return 3;
    pthread_exit(NULL);
}
''')
            subprocess.run(["cc", "-pthread", str(source), "-o", str(binary)], check=True, timeout=30)
            spawned = []
            original_spawn = subprocess.Popen
            def spawn(*args, **kwargs):
                process = original_spawn(*args, **kwargs)
                if args[0][0] == str(binary):
                    spawned.append(process)
                return process
            observed_live_worker = False
            original_lookup = runner.test_process
            def lookup(pid):
                nonlocal observed_live_worker
                info = original_lookup(pid)
                if spawned and pid == spawned[0].pid and info is not None:
                    fields = Path(f"/proc/{pid}/stat").read_bytes().rsplit(b")", 1)[1].split()
                    if fields[0] == b"Z" and int(fields[17]) > 1:
                        self.assertFalse(info.zombie)
                        observed_live_worker = True
                return info
            try:
                with patch.object(runner.subprocess, "Popen", side_effect=spawn), \
                        patch.object(runner, "test_process", side_effect=lookup):
                    self.assertEqual(runner.run_command([str(binary), str(stop)], timeout=1), 124)
                self.assertTrue(observed_live_worker, "fixture did not expose the Linux zombie-leader state")
                self.assertEqual(len(spawned), 1)
                self.assertEqual(spawned[0].returncode, -signal.SIGKILL)
                self.assertFalse(Path(f"/proc/{spawned[0].pid}").exists())
            finally:
                stop.touch()
                for process in spawned:
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=2)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fixture":
        fixture(sys.argv[2], sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else 0)
    else:
        unittest.main()
