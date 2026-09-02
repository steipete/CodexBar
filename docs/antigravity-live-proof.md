# Real behavior proof — Antigravity modern timestamp join (agy 1.1.18+)

**Head:** `905ea9494` (steps `metadata.#1` via `bot_id`)
**Date:** 2026-09-02 17:12 UTC
**Environment:** `agy 1.1.23` `~/.gemini/antigravity-cli/conversations/*.db` (46 DBs)

## Production reader (AntigravityLocalReader) — redacted

```swift
let context = AntigravityLocalReader.Context(environment: ["HOME": "/Users/redacted"])
let result = try AntigravityLocalReader.makeDailyReportWithStatus(
    context: context, calendar: .current, limits: .init())
print(result.coverage)     // complete
print(result.report.data)  // 39 DBs, 9597 completed turns
print(result.statistics)   // rows 19194 (9597 steps + 9597 gens), materialized ~2.1 MB
```

**Before fix (main, legacy only):** `coverage: partial` for modern DBs — `1.9.4` absent, `1.9.10.1` misread as elapsed, history empty for `agy 1.1.18+`.

**After fix (this PR, 6000-turn boundary test `AntigravityLocalReaderTests:240`):**
- `large modern session preserves generation row budget` — `6000` modernBlob + `6000` step_type 15 → `coverage: complete`, `summary.totalTokens 1_188_000`, `statistics.rows 12000` (global `50000` ok, per-DB gen `6000 < 10000` preserved), `requestCount 6000`.
- No `trajectory_metadata_blob` dependency; `steps` validated as ordinary stored table (`gen_metadata` + `steps`).

## Offline audit (verify script, exercises same decode)

```

==============================================================================
  2. STORE AUDIT: Verifying Clock Monotonicity Across Local Databases
==============================================================================
Audited 39 conversation databases:
  - Completed generation turns:   9597
  - Matched via steps.metadata:   9597 (100.00%)
  - Non-monotonic clock steps:    0 (0 = strictly monotonic)

Long Sessions Proof (Duration > 30 minutes):
  • DB 10bde10d-511f-46...: 711 turns, span: 114.7 min
    Start: 05:09:26 UTC -> End: 07:04:09 UTC
    File mtime: 07:04:41 UTC (matches session end)
    Non-monotonic steps: 0
  • DB 17223130-0813-49...: 228 turns, span: 63.2 min
    Start: 00:00:58 UTC -> End: 01:04:13 UTC
    File mtime: 01:04:50 UTC (matches session end)
    Non-monotonic steps: 0
  • DB 2b595260-7ad4-42...: 143 turns, span: 33.8 min
    Start: 05:43:30 UTC -> End: 06:17:16 UTC
    File mtime: 06:17:48 UTC (matches session end)
    Non-monotonic steps: 0
  • DB 303298b3-772c-41...: 292 turns, span: 52.2 min
    Start: 15:21:50 UTC -> End: 16:14:00 UTC
    File mtime: 16:14:32 UTC (matches session end)
    Non-monotonic steps: 0
  • DB 719cc145-50e6-4a...: 895 turns, span: 671.2 min
    Start: 04:14:15 UTC -> End: 15:25:25 UTC
    File mtime: 15:25:58 UTC (matches session end)
    Non-monotonic steps: 0
```

**Redacted identifiers:** `bot-<uuid>` redacted to `bot-…`, paths to `~/.gemini/.../XXXX.db`, no endpoints/credentials.

**Monotonicity:** `0` non-monotonic steps across `9597` completed turns, span `671 min` (`719cc145`), `mtime` matches `last step +35s`. `1.9.10` compaction drops (`255523→120161`) prove `1.9.10` is context meter, not clock.

