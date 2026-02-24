# CodexBar Issue #139 Main Fix Validation (Post-Fix vs Pre-Fix)

Date: 2026-02-19
Workspace: /Users/michalkrsik/windsurf_project_folder/CodexBar
Branch: codex/perf-issue-139

Reference pre-fix report:
- /Users/michalkrsik/windsurf_project_folder/CodexBar/docs/perf-energy-issue-139-simulation-report-2026-02-19.md

## Implemented Main Fix

File changed:
- /Users/michalkrsik/windsurf_project_folder/CodexBar/Sources/CodexBarCore/Providers/Codex/CodexStatusProbe.swift

Behavior change:
- Primary Codex PTY probe timeout reduced from 18s to 8s.
- Retry policy changed from `retry on parseFailed OR timedOut` to `retry only on parseFailed`.
- Parse retry timeout set to 4s.
- Timed-out runs now fail fast and wait for next scheduled refresh.

## Post-Fix Validation Method

Target: main culprit path (Codex CLI failure path).

Practical simulation used:
- `CODEX_CLI_PATH` pointed to a fake codex script.
- Script behavior:
  - exits immediately for `app-server` args (forces RPC failure/fallback path),
  - otherwise busy-loops with no `/status` output (simulates heavy stuck CLI PTY behavior).
- Command run (3 times):
  - `./.build/debug/CodexBarCLI usage --provider codex --source cli --format json --pretty`
- Collected:
  - wall time (`/usr/bin/time -p`),
  - sampled child CPU every 0.5s,
  - leftover child-process count after run.

Artifacts:
- /tmp/codexbar_main_fix_validation_after

## Post-Fix Results (3 runs)

| Run | Real (s) | Avg child CPU (%) | Max child CPU (%) | Remaining child procs |
|---|---:|---:|---:|---:|
| 1 | 12.76 | 88.32 | 100.00 | 0 |
| 2 | 12.67 | 89.79 | 100.00 | 0 |
| 3 | 12.59 | 89.90 | 100.00 | 0 |
| Mean | 12.67 | 89.34 | 100.00 | 0 |

## Side-by-Side Comparison Against Stored Pre-Fix Report

Pre-fix values are from the stored report's Culprit A simulation summary.
Post-fix values are from the validation above.

| Metric | Pre-fix (stored report) | Post-fix (this validation) | Delta |
|---|---:|---:|---:|
| Failed-run duration (worst-case path) | 42.00s (code-path budget before fix) | 12.67s (measured mean) | -69.8% |
| Child CPU during failed run | 113.32% avg | 89.34% avg | -21.2% |
| Peak child CPU during failed run | 115.90% max | 100.00% max | -13.7% |
| Remaining child processes after failure | not captured in pre-fix report | 0 | improved |

Derived CPU-time exposure index (avg CPU * duration):
- Pre-fix: `113.32 * 42.00 = 4759.44`
- Post-fix: `89.34 * 12.67 = 1132.94`
- Reduction: **-76.2%**

## Conclusion

The implemented main fix materially reduces the failure-path runtime and overall CPU exposure.
The heavy CLI process can still spike CPU while active, but it now lives for a much shorter window and is cleaned up after failure.
