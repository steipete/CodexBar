#!/usr/bin/env python3
"""Reuse verified Git-tracked input mtimes and invalidate backdated changes."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import secrets
import stat
import subprocess
import time

SCHEMA = 3
DEFAULT_METADATA = ".build/ci-inputs.json"
MAX_METADATA_BYTES = 16 * 1024 * 1024
LANES = ("macos26-arm64", "macos15-arm64")
CONTEXT_INPUTS = (
    "Package.swift", "Package.resolved", ".github/workflows/ci.yml",
    "Scripts/ci_swiftpm_cache.py", "Scripts/test.sh", "Scripts/test_environment.sh",
    "Scripts/ci_swift_test_by_suite.py", "Scripts/direct_swift_test_groups.py",
)
BUILD_INPUT_PREFIXES = ("Sources/", "Tests/", "TestsPlugin/", "TestsLinux/", "WidgetExtension/")


def build_context(root, lane):
    """Bind build reuse to the selected toolchain, SDK, dependencies and flags."""
    root = Path(root).resolve()
    if lane not in LANES:
        raise ValueError("unsupported cache lane")

    def output(*args):
        return subprocess.check_output(args, cwd=root, text=True).strip()

    description = {
        "schema": SCHEMA,
        "lane": lane,
        "architecture": platform.machine(),
        "xcode": output("xcodebuild", "-version"),
        "swift": output("swift", "--version"),
        "sdk_path": output("xcrun", "--sdk", "macosx", "--show-sdk-path"),
        "sdk_version": output("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "sdk_build": output("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
        # The help text also binds the default build system on each Swift version.
        "build_options": output("swift", "build", "--help"),
        "configuration": "debug-build-tests",
        "inputs": {
            name: hashlib.sha256((root / name).read_bytes()).hexdigest()
            for name in CONTEXT_INPUTS
        },
    }
    encoded = json.dumps(description, sort_keys=True, separators=(",", ":")).encode()
    context = hashlib.sha256(encoded).hexdigest()
    return {"context": context, "prefix": f"swiftpm-compiled-v1-{lane}-{context}-"}


def relative_path(value):
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ValueError("invalid input path")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or str(path) != value or value == ".":
        raise ValueError("input path must be canonical and repository-relative")
    return path.parts


def tracked_files(root):
    output = subprocess.check_output(["git", "ls-files", "--stage", "-z"], cwd=root)
    files = {}
    for entry in output.split(b"\x00"):
        if not entry:
            continue
        header, name = entry.split(b"\t", 1)
        mode, _, stage = header.decode("ascii").split()
        path = os.fsdecode(name)
        relative_path(path)
        if stage != "0":
            raise ValueError("unmerged inputs cannot seed a build cache")
        if mode in {"100644", "100755", "120000"}:
            files[path] = mode
    return files


def open_parent(root_fd, name):
    """Open a parent directory without following any symlink ancestors."""
    parts = relative_path(name)
    parent = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        return parent, parts[-1]
    except BaseException:
        os.close(parent)
        raise


def open_input(root_fd, name):
    """Open every component without following symlinks, including ancestors."""
    parent, leaf = open_parent(root_fd, name)
    try:
        fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            raise ValueError("input is not a regular file")
        return fd
    finally:
        os.close(parent)


def symlink_record(root_fd, name, verified_targets=None):
    """Hash the link payload itself; never read or modify its target."""
    parent, leaf = open_parent(root_fd, name)
    try:
        before = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISLNK(before.st_mode):
            raise ValueError("input is not a symlink")
        payload = os.fsencode(os.readlink(leaf, dir_fd=parent))
        after = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
        identity = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(getattr(before, key) != getattr(after, key) for key in identity):
            raise ValueError("symlink changed while hashing")
        if verified_targets is not None:
            # A stable link payload does not prove its target's contents. Only
            # regular tracked files in both snapshots enter the content-hash loop.
            target = os.path.normpath(os.path.join(os.path.dirname(name), os.fsdecode(payload)))
            relative_path(target)
            # Collapsing link/../ could otherwise conceal an unverified ancestor.
            canonical = os.path.relpath(target, os.path.dirname(name) or ".")
            if os.fsdecode(payload) != canonical or target not in verified_targets:
                raise ValueError("symlink target is not a verified regular input")
            fd = open_input(root_fd, target)
            os.close(fd)
        return {
            "sha256": hashlib.sha256(payload).hexdigest(),
            "size": len(payload),
            "mtime_ns": after.st_mtime_ns,
            "git_mode": "120000",
            "file_mode": stat.S_IMODE(after.st_mode),
        }
    finally:
        os.close(parent)


def input_record(fd, git_mode):
    before = os.fstat(fd)
    digest = hashlib.sha256()
    while chunk := os.read(fd, 1024 * 1024):
        digest.update(chunk)
    after = os.fstat(fd)
    if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
        after.st_size, after.st_mtime_ns, after.st_ctime_ns
    ):
        raise ValueError("input changed while hashing")
    return {
        "sha256": digest.hexdigest(),
        "size": after.st_size,
        "mtime_ns": after.st_mtime_ns,
        "git_mode": git_mode,
        "file_mode": stat.S_IMODE(after.st_mode),
    }


def snapshot(root, metadata, context):
    root = Path(root).resolve()
    parts = relative_path(metadata)
    files = {}
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for name, mode in tracked_files(root).items():
            try:
                if mode == "120000":
                    files[name] = symlink_record(root_fd, name)
                    continue
                fd = open_input(root_fd, name)
                try:
                    files[name] = input_record(fd, mode)
                finally:
                    os.close(fd)
            except (OSError, ValueError):
                # Unavailable inputs retain their fresh checkout timestamps on restore.
                continue
    finally:
        os.close(root_fd)
    document = {"schema": SCHEMA, "context": context, "files": files}
    parent = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    temporary = f".ci-inputs-{secrets.token_hex(8)}"
    try:
        for part in parts[:-1]:
            try:
                os.mkdir(part, dir_fd=parent)
            except FileExistsError:
                pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(document, output, sort_keys=True, separators=(",", ":"))
            output.write("\n")
        os.replace(temporary, parts[-1], src_dir_fd=parent, dst_dir_fd=parent)
    finally:
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)
    return {"recorded": len(files), "metadata": metadata}


def read_metadata(root_fd, metadata, context):
    fd = open_input(root_fd, metadata)
    try:
        if os.fstat(fd).st_size > MAX_METADATA_BYTES:
            raise ValueError("metadata exceeds size limit")
        with os.fdopen(os.dup(fd), "r", encoding="utf-8") as source:
            document = json.load(source)
    finally:
        os.close(fd)
    if not isinstance(document, dict) or document.get("schema") != SCHEMA:
        raise ValueError("metadata schema mismatch")
    if document.get("context") != context:
        raise ValueError("toolchain or build context mismatch")
    files = document.get("files")
    if not isinstance(files, dict) or len(files) > 50000:
        raise ValueError("invalid metadata input map")
    for name, record in files.items():
        relative_path(name)
        if not isinstance(record, dict):
            raise ValueError("invalid input record")
        if not re.fullmatch(r"[a-f0-9]{64}", str(record.get("sha256", ""))):
            raise ValueError("invalid input digest")
        if record.get("git_mode") not in {"100644", "100755", "120000"}:
            raise ValueError("invalid input mode")
        if type(record.get("size")) is not int or record["size"] < 0:
            raise ValueError("invalid input size")
        if type(record.get("mtime_ns")) is not int or not 0 < record["mtime_ns"] <= time.time_ns():
            raise ValueError("invalid input timestamp")
        if type(record.get("file_mode")) is not int or not 0 <= record["file_mode"] <= 0o7777:
            raise ValueError("invalid input permissions")
    return files


def restore(root, metadata, context):
    root = Path(root).resolve()
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    result = {"restored": 0, "changed": 0, "missing": 0, "unavailable": 0, "verified_symlinks": 0}
    try:
        try:
            files = read_metadata(root_fd, metadata, context)
            tracked = tracked_files(root)
        except (OSError, ValueError, UnicodeError, RecursionError) as error:
            return {**result, "fallback": str(error)}

        def build_inputs(names):
            return {name for name in names if name in {"Package.swift", "Package.resolved"}
                    or name.startswith(BUILD_INPUT_PREFIXES)}

        cached_inputs, current_inputs = build_inputs(files), build_inputs(tracked)
        if cached_inputs != current_inputs:
            # SwiftPM can leave removed .process resources in an old bundle.
            # Reuse checkouts, but clean products when the input graph changes.
            return {**result, "missing": len(current_inputs - cached_inputs),
                    "removed": len(cached_inputs - current_inputs), "fallback": "build input paths changed"}

        # Equal target sizes/mtimes can hide a retargeted link from SwiftPM.
        # Check every package symlink and type transition before restoring any mtimes.
        verified_targets = {name for name, mode in tracked.items()
                            if mode in {"100644", "100755"}
                            and files.get(name, {}).get("git_mode") in {"100644", "100755"}}
        for name in sorted(current_inputs):
            if "120000" not in {tracked[name], files[name]["git_mode"]}:
                continue
            if tracked[name] != files[name]["git_mode"]:
                return {**result, "changed": 1, "fallback": "build input symlink type changed"}
            try:
                current = symlink_record(root_fd, name, verified_targets)
            except (OSError, ValueError):
                return {**result, "unavailable": 1, "fallback": "build input symlink could not be verified"}
            if any(current[key] != files[name][key] for key in ("sha256", "size")):
                return {**result, "changed": 1, "fallback": "build input symlink target changed"}
            result["verified_symlinks"] += 1

        for name, git_mode in tracked.items():
            if git_mode == "120000":
                continue
            cached = files.get(name)
            if cached is None:
                result["missing"] += 1
                continue
            try:
                fd = open_input(root_fd, name)
                try:
                    current = input_record(fd, git_mode)
                    if any(current[key] != cached[key] for key in ("sha256", "size", "git_mode", "file_mode")):
                        # Some checkout/copy tools preserve timestamps. A changed input
                        # must not look identical to the compiler's previous build record.
                        if current["mtime_ns"] <= cached["mtime_ns"]:
                            changed_ns = max(time.time_ns(), cached["mtime_ns"] + 1)
                            os.utime(fd, ns=(os.fstat(fd).st_atime_ns, changed_ns))
                        result["changed"] += 1
                        continue
                    # Use the verified descriptor: path replacement cannot redirect this write.
                    os.utime(fd, ns=(os.fstat(fd).st_atime_ns, cached["mtime_ns"]))
                    result["restored"] += 1
                finally:
                    os.close(fd)
            except (OSError, ValueError):
                result["unavailable"] += 1
        if result["unavailable"]:
            result["fallback"] = "some checkout inputs could not be verified"
        return result
    finally:
        os.close(root_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("snapshot", "restore", "context"))
    parser.add_argument("--root", default=".")
    parser.add_argument("--metadata", default=DEFAULT_METADATA)
    parser.add_argument("--context")
    parser.add_argument("--lane", choices=LANES)
    parser.add_argument("--clean-fallback", action="store_true")
    args = parser.parse_args()
    if args.action == "context":
        if not args.lane:
            parser.error("a cache lane is required")
        result = build_context(args.root, args.lane)
        if path := os.environ.get("GITHUB_OUTPUT"):
            with open(path, "a", encoding="utf-8") as output:
                for key, value in result.items():
                    output.write(f"{key}={value}\n")
        print(json.dumps(result, sort_keys=True))
        return
    if not args.context:
        parser.error("a nonempty build context is required")
    function = snapshot if args.action == "snapshot" else restore
    result = function(args.root, args.metadata, args.context)
    if args.action == "restore" and args.clean_fallback and "fallback" in result:
        subprocess.run(["swift", "package", "clean"], cwd=args.root, check=True)
        result["cleaned"] = True
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
