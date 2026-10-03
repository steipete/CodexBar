#!/usr/bin/env python3
"""Opt-in macOS direct test launch using the selected SwiftPM toolchain helpers.

SwiftPM remains responsible for building and discovery. Each test group retains a fresh
process, contained descendants, deadline, and an isolated home. Hosted CI stays serial.
"""
from __future__ import annotations

import concurrent.futures
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

from ci_swift_test_by_suite import TestSelection, filter_for, run_command


def runtime_environment(developer: Path, home: Path) -> dict[str, str]:
    environment = os.environ.copy()
    platform = developer / "Platforms/MacOSX.platform/Developer"
    for key, directory in [("DYLD_FRAMEWORK_PATH", platform / "Library/Frameworks"),
                           ("DYLD_LIBRARY_PATH", platform / "usr/lib")]:
        environment[key] = str(directory) + (":" + environment[key] if environment.get(key) else "")
    environment["CFFIXED_USER_HOME"] = str(home)
    environment["CODEXBAR_TEST_CODEX_FILE_ISOLATION"] = "1"
    environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] = "1"
    environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] = "1"
    environment.pop("CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS", None)
    environment.pop("CODEXBAR_TEST_CODEX_FILE_FIXTURES", None)
    environment["LANG"] = "en_US.UTF-8"
    environment["LC_ALL"] = "en_US.UTF-8"
    return environment


def checked(command: list[str], environment: dict[str, str], timeout: int = 60) -> str:
    result = subprocess.run(command, env=environment, text=True, capture_output=True, timeout=timeout)
    if result.returncode != 0:
        # Do not print helper diagnostics: XCTest can include the inherited environment.
        raise ValueError(f"Direct runtime capability probe failed (exit {result.returncode}).")
    return result.stdout


def xctest_inventory(value: dict) -> list[str]:
    result = []
    for suite in value.get("tests", []):
        for test_case in suite.get("tests", []):
            for method in test_case.get("tests", []):
                result.append(test_case["name"] + "/" + method["name"])
    return result


def selected_tests(inventory: list[str], selections: list[dict]) -> list[str]:
    pattern = re.compile(filter_for([TestSelection(**selection) for selection in selections]))
    return [name for name in inventory if pattern.search(name)]


def prepare_runtime(swift_command: list[str], groups: list[list[dict]], expected: list[str], directory: Path) -> dict:
    if sys.platform != "darwin" or os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS"):
        raise ValueError("Direct test groups are an opt-in local macOS mode.")
    if swift_command != ["swift"]:
        raise ValueError("Direct launch requires the default selected Swift toolchain.")
    developer = Path(checked(["xcode-select", "-p"], os.environ.copy()).strip())
    swift = Path(checked(["xcrun", "--find", "swift"], os.environ.copy()).strip())
    helper_root = swift.parent.parent / "libexec/swift/pm"
    testing_helper = helper_root / "swiftpm-testing-helper"
    xctest_helper = helper_root / "swiftpm-xctest-helper"
    xctest = Path(checked(["xcrun", "--find", "xctest"], os.environ.copy()).strip())
    frameworks = developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
    if not all(path.exists() for path in [testing_helper, xctest_helper, xctest, frameworks]):
        raise ValueError("The selected toolchain lacks the direct macOS test runtime.")
    bin_path = Path(checked(["swift", "build", "--show-bin-path"], os.environ.copy()).strip())
    bundles = sorted(bin_path.glob("*.xctest"))
    if not bundles:
        raise ValueError("No prebuilt test bundles found.")
    home = directory / "probe-home"
    home.mkdir()
    environment = runtime_environment(developer, home)
    products = []
    all_names = []
    for index, bundle in enumerate(bundles):
        binary = bundle / "Contents/MacOS" / bundle.stem
        if not binary.is_file():
            raise ValueError("Unsupported test bundle layout.")
        output = directory / f"xctest-{index}.json"
        checked([str(xctest_helper), str(bundle), str(output)], environment)
        xctests = xctest_inventory(json.loads(output.read_text()))
        swift_tests = checked([str(testing_helper), "--test-bundle-path", str(binary),
                               "--list-tests", "--testing-library", "swift-testing"], environment).splitlines()
        all_names.extend(xctests + swift_tests)
        products.append({"bundle": str(bundle), "binary": str(binary), "xctest": xctests, "swift": swift_tests})
    if len(all_names) != len(set(all_names)) or set(all_names) != set(expected):
        raise ValueError("Direct runtime inventory differs from SwiftPM discovery; using serial fallback.")
    for group in groups:
        if not selected_tests(all_names, group):
            raise ValueError("A selected group is absent from direct runtime discovery.")
    return {"developer": str(developer), "testing_helper": str(testing_helper), "xctest": str(xctest),
            "products": products}


def run_worker(manifest: dict, index: int) -> int:
    with tempfile.TemporaryDirectory(prefix=f"codexbar-direct-group-{index}-") as directory:
        environment = runtime_environment(Path(manifest["runtime"]["developer"]), Path(directory))
        os.environ.clear()
        os.environ.update(environment)
        group = manifest["groups"][index]
        timeout = manifest["timeout"]
        commands = []
        runtime = manifest["runtime"]
        for product in runtime["products"]:
            xctests = selected_tests(product["xctest"], group)
            swift_tests = selected_tests(product["swift"], group)
            if xctests:
                commands.append([runtime["xctest"], "-XCTest", ",".join(xctests), product["bundle"]])
            if swift_tests:
                commands.append([runtime["testing_helper"], "--test-bundle-path", product["binary"],
                                 "--filter", filter_for([TestSelection(**selection) for selection in group]),
                                 "--no-parallel", "--testing-library", "swift-testing"])
        if not commands:
            return 2
        started = time.monotonic()
        # The parent deadline bounds the whole group, including all test products and cleanup.
        for command in commands:
            remaining = timeout - (time.monotonic() - started)
            if remaining <= 0:
                return 124
            os.environ["SWIFT_TESTING_ENABLED"] = "0" if command[0] == runtime["xctest"] else "1"
            result = run_command(command, remaining)
            if result != 0:
                return result
        return 0


def run_pool(manifest_path: Path) -> int:
    manifest = json.loads(manifest_path.read_text())
    script = Path(__file__).resolve()
    def launch(index: int) -> dict:
        log = manifest_path.parent / f"group-{index}.log"
        with log.open("w") as output:
            result = subprocess.run([sys.executable, str(script), "--worker", str(manifest_path), str(index)],
                                    stdout=output, stderr=subprocess.STDOUT)
        code = result.returncode
        first_code = code
        full_retries = 0
        isolated_retries = 0
        if code != 0 and code != 124 and manifest["retry_non_timeout_failures"] and len(manifest["groups"][index]) > 1:
            full_retries += 1
            with log.open("a") as output:
                output.write("Retrying failed group once in a fresh process.\n")
                output.flush()
                code = subprocess.run([sys.executable, str(script), "--worker", str(manifest_path), str(index)],
                                      stdout=output, stderr=subprocess.STDOUT).returncode
        if code == 124 and len(manifest["groups"][index]) > 1:
            for selection in manifest["groups"][index]:
                isolated_retries += 1
                isolated = dict(manifest)
                isolated["groups"] = [[selection]]
                retry_manifest = manifest_path.parent / f"retry-{index}.json"
                retry_manifest.write_text(json.dumps(isolated))
                with log.open("a") as output:
                    code = subprocess.run([sys.executable, str(script), "--worker", str(retry_manifest), "0"],
                                          stdout=output, stderr=subprocess.STDOUT).returncode
                if code != 0:
                    break
        return {"code": code, "first_code": first_code, "full_retries": full_retries,
                "isolated_retries": isolated_retries}
    failed = False
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=manifest["workers"]) as pool:
        futures = {pool.submit(launch, index): index for index in range(len(manifest["groups"]))}
        for future in concurrent.futures.as_completed(futures):
            index = futures[future]
            record = future.result()
            results.append(record)
            code = record["code"]
            print(f"::group::Direct Swift test group {index + 1}/{len(futures)}", flush=True)
            print((manifest_path.parent / f"group-{index}.log").read_text(), flush=True)
            print("::endgroup::", flush=True)
            failed |= code != 0
    (manifest_path.parent / "results.json").write_text(json.dumps(results))
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--worker":
        raise SystemExit(run_worker(json.loads(Path(sys.argv[2]).read_text()), int(sys.argv[3])))
    if len(sys.argv) == 2:
        raise SystemExit(run_pool(Path(sys.argv[1])))
    raise SystemExit(2)
