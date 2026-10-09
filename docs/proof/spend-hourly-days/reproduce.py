"""Verify hourly navigation with synthetic tests; optionally print date-list CPU timings."""

import argparse
import os
from pathlib import Path
import subprocess

REPOSITORY = Path(__file__).resolve().parents[3]

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("command", choices=["verify", "benchmark"])
arguments = parser.parse_args()
environment = os.environ.copy()
environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] = "0"
environment["CODEXBAR_HOURLY_DAYS_BENCHMARK"] = "1" if arguments.command == "benchmark" else "0"
subprocess.run(
    ["/bin/bash", "-c", "source Scripts/test_environment.sh && "
     "swift test --build-system native --jobs 4 -Xswiftc -gnone --no-parallel --filter SpendTrendHourlyDaysTests"],
    cwd=REPOSITORY,
    env=environment,
    check=True,
)
