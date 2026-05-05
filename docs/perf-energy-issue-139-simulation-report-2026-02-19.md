# CodexBar Issue #139 Performance/Energy Simulation Report

Date: 2026-02-19
Workspace: /Users/michalkrsik/windsurf_project_folder/CodexBar
Issue: https://github.com/steipete/codexbar/issues/139

## Purpose

Determine which suspected culprit(s) can produce the abnormal CPU/energy behavior reported by users, using short reproducible simulations and process-level sampling.

## Host/Tooling

- macOS: Darwin 25.2.0 (arm64)
- Swift: 6.2.3
- Sampling tools: `ps`, `top`
- Note: `powermetrics` was unavailable (requires sudo password in this session), so energy was sampled via `top` `POWER` proxy.

## Simulated Culprits

- Culprit A: CLI/PTTY-style heavy subprocess churn with polling loop behavior.
- Culprit B: Web dashboard scrape/retry loop with repeated parse work and 400-600ms waits.
- Culprit C: 75ms idle polling loop (blink-style wakeups).
- Combined: A + B + C at once.
- Baseline: near-idle control.

## Test Pass 1 (Primary Mechanism Pass)

Artifacts:
- /tmp/codexbar_perf_sim/results_20260219_111607

Summary:

| Scenario | Avg CPU | Max CPU | Avg RSS MB | Avg POWER | Avg IDLEW |
|---|---:|---:|---:|---:|---:|
| Baseline | 0.00 | 0.10 | 0.54 | 0.00 | 0.00 |
| Culprit A | 113.68 | 117.40 | 121.76 | 0.00 | 0.00 |
| Culprit B | 4.64 | 13.30 | 64.15 | 0.00 | 5.04 |
| Culprit C | 0.25 | 2.30 | 33.12 | 0.00 | 10.43 |
| Combined | 114.62 | 121.30 | 217.62 | 0.00 | 0.00 |

Interpretation:
- CPU ranking was clear (A dominates strongly).
- POWER field in this pass was unusable (stuck at 0.00 for several scenarios due `top` sampling mode).

## Test Pass 2 (Calibrated Energy Pass)

Artifacts:
- /tmp/codexbar_perf_sim/energy2_results_20260219_112350

Sampling correction:
- Switched to `top -l 2` and parsed the second sample for tracked PIDs to get non-zero `POWER` values.

Summary:

| Scenario | Avg CPU | Max CPU | Avg RSS MB | Avg POWER | Max POWER | Avg IDLEW |
|---|---:|---:|---:|---:|---:|---:|
| Baseline | 0.00 | 0.00 | 0.55 | 0.00 | 0.00 | 0.00 |
| Culprit A | 113.32 | 115.90 | 114.73 | 94.85 | 150.60 | 6106.70 |
| Culprit B | 4.30 | 10.10 | 62.09 | 2.94 | 4.20 | 2.18 |
| Culprit C | 0.35 | 2.60 | 34.09 | 0.23 | 0.60 | 14.27 |
| Combined | 115.67 | 118.90 | 218.48 | 93.29 | 129.60 | 3858.60 |

## Validation Against Expected Pattern

Computed checks on pass 2: 10/10 passed.

- A dominates CPU vs B (>=10x): PASS
- A dominates CPU vs C (>=50x): PASS
- A dominates POWER vs B (>=10x): PASS
- A dominates POWER vs C (>=100x): PASS
- Combined close to A CPU (+/-15%): PASS
- Combined close to A POWER (+/-25%): PASS
- C is low CPU (<1%): PASS
- B is moderate CPU (<15%): PASS
- Baseline near zero CPU (<1%): PASS
- Baseline near zero POWER (<1): PASS

## Final Finding

Primary root-cause class for the extreme behavior is Culprit A (heavy long-lived CLI/subprocess churn under bad/failure paths).

Secondary:
- Culprit B contributes moderate load.
- Culprit C contributes wakeups/noise but is not a major CPU/energy driver.

Human-level answer:
A tiny toolbar app should never keep heavyweight background subprocess/UI loops alive in failure conditions. That behavior is what creates the abnormal battery/CPU footprint.

## Limitations

- These were controlled simulations, not a full end-user UI replay of `CodexBar.app` with all real auth/cookie/account paths.
- `powermetrics` could not be used in this session due sudo restriction.

## Recommended Next Validation (Before Closing Issue)

- Run one short real-app before/after validation after fixes:
  - baseline
  - culprit A-focused repro
  - optional combined
- Capture `powermetrics` if sudo is available, plus process CPU snapshots.
- Publish before/after table in issue #139.
