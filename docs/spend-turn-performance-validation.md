---
summary: "Metric contract and synthetic verification for native Codex turn performance."
read_when:
  - Reviewing turn throughput or first-token timing in spend sessions
  - Reproducing the synthetic turn-performance checks
---

# Native Codex turn performance

Usage & Spend retains its cost-ranked session header and adds timing only when
validated native Codex samples exist. The primary strip shows weighted whole-turn
output, median model-first-token latency, median completed-turn duration, and
cached-input reuse. First-token and cache sample counts appear beside their
measurements; missing cache records show unavailable, while measured zero reuse
shows 0.0%.
The initially collapsed **Performance details** disclosure shows the timed-turn
count. First model token may be reasoning, before visible answer text. Output
already includes reasoning tokens; elapsed time includes tools and waits. These
observations are not a model streaming-speed benchmark.

## Sample and billing boundaries

A successful `task_complete` joins deduplicated, owned `token_usage_record`
responses by turn ID in the existing local request ledger. The summed output
must match the reported turn total. Failed/incomplete turns, malformed owned
usage, invalid completion timestamps, invalid supplied start times, nonpositive
durations, and overflowing output totals do not produce samples. Missing or
invalid first-token timing leaves that latency unavailable without removing a
valid whole-turn observation. Copied parent requests remain excluded.

Timing follows completion day in the selected cost calendar. Selecting a chart
day filters timing; clearing it restores the range. A turn may complete after
midnight while all its billed requests remain on the preceding day. Billing
keeps the original request dates, pricing, and existing range totals. Other
providers and OpenCodex do not acquire timing from native Codex samples.

Parser revision 12 uses the existing bounded reparse and saved-pricing migration.
Compatible predecessor stores retain their rows and checkpoints while timing is
backfilled. A missing source log leaves its existing billing history intact.
There are no new dependencies, probes, or credentials.

## Detail statistics

- P95 uses nearest-rank percentiles and requires 20 valid observations per metric.
  Missing first-token observations do not reduce the duration sample count.
- The middle 50% of per-turn output rates uses nearest-rank P25–P75 and needs four
  completed turns. Sample thresholds are not statistical confidence guarantees.
- Cache fraction is cached input divided by input across eligible samples, with
  coverage shown. Input already includes cached tokens. Zero or overflowing
  totals leave the ratio unavailable.
- Model/effort groups show counts, weighted output, and median latencies. Effort
  comes from the owning turn context. Missing, mixed, or conflicting attribution
  remains unknown; grouping does not rank model capabilities.

## Verification

Run the following with the repository's scrubbed test environment:

```sh
source Scripts/test_environment.sh
swift test --build-system native --jobs 4 -Xswiftc -gnone \
  --filter 'CostUsage(Turn|RequestLedger|Store|CoverageCompatibility)|SpendSessionPerformance'
make check
```

The fixtures cover duplicate ownership, incomplete and malformed timing,
completion-only appends, midnight boundaries, sample thresholds, provider
isolation, and bounded predecessor backfill preserving ledger rows and prices.
The existing ledger and migration suites check the billing boundary.

For a headless render of production session rows, set
`CODEXBAR_PERFORMANCE_UI_PROOF_DIR` to an empty output directory and optionally
`CODEXBAR_PERFORMANCE_UI_PROOF_WIDTH` (for example, 420), then run
`SpendSessionPerformanceTests`. The renderer uses only synthetic values and
covers English/Chinese, light/dark, and privacy masking. It does not launch the
app or claim installed-window responsiveness. Historical contributor receipts
remain in the history of PR #4304 rather than being shipped as benchmark logs.
