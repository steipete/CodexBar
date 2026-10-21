#!/usr/bin/env python3
"""Run native SwiftPM selection with the shared test-process containment."""

import os
import sys
import tempfile

from ci_swift_test_by_suite import containment_support_error, run_command


def main() -> int:
    try:
        timeout = int(os.environ.get("CODEXBAR_TEST_NATIVE_TIMEOUT", "1800"))
        if timeout <= 0:
            raise ValueError
    except ValueError:
        print("CODEXBAR_TEST_NATIVE_TIMEOUT must be a positive integer", file=sys.stderr)
        return 2

    error = containment_support_error()
    if error is not None:
        print(error, file=sys.stderr)
        return 2
    # Like serial groups, the whole invocation, including its build, gets temporary HOME and
    # CFFIXED_USER_HOME values instead of the caller's.
    with tempfile.TemporaryDirectory(prefix="codexbar-native-test-home-") as home:
        return run_command(["swift", "test", "--no-parallel", *sys.argv[1:]], timeout=timeout,
                           environment=os.environ | {"HOME": home, "CFFIXED_USER_HOME": home})


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130) from None
