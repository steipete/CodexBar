# Spec: Contain Ultra-mode interleaved-lineage token overcounting (issue #2037)

- **Issue:** [steipete/CodexBar#2037](https://github.com/steipete/CodexBar/issues/2037) — "Ultra-mode Terra and Sol sessions can overcount forked context"
- **Status:** Implemented (rev 4 — Phase 1 post-latch containment + min-cap)
- **Affected code:** `Sources/CodexBarCore/Vendored/CostUsage/` (Codex session scanner)
- **Related prior fixes:** #968 (divergent totals), #1062 (repeated total snapshots), commit `45b68c34` (fork replay)

## 0. Framing (read first)

This spec deliberately ships in two phases:

- **Phase 1 (this PR): containment.** Stop the multiplicative blowup and guarantee a *never-inflates* property. In multi-lineage files the result is an explicitly **conservative estimate** — it can undercount genuine totals-only sub-agent usage. We do not claim "true per-lineage usage."
- **Phase 2 (follow-up, fixture-gated): per-lineage accounting.** Candidate-baseline run tracking to recover undercounted totals-only lineages. Blocked on obtaining a sanitized real Ultra fixture (§8), because its correctness depends on empirical `last_token_usage` semantics that cannot be asserted from first principles.

## 1. Problem

CodexBar massively overstates usage for `gpt-5.6-terra` and especially `gpt-5.6-sol` when they run in Ultra mode. In one reported Sol session, the raw log reached roughly **268M** cumulative input tokens while CodexBar attributed **3.29B** input tokens and about $4,000 of standard cost. A single forked turn contributed more than 3B tokens across hundreds of rows. Pricing tables are correct; the inflation comes from usage accounting.

Ultra sessions fork multiple sub-agents that:

1. write **interleaved cumulative token snapshots** (`total_token_usage`) into the *same* session JSONL file, and
2. **replay large portions of the parent context** into sub-agent turns.

## 2. Definitions

**Lineage:** one monotonic cumulative-counter sequence (`total_token_usage`) produced by one agent/sub-agent. Ultra files interleave several lineages with no reliable lineage identifier on token events (`turn_id` cannot be used: cumulative counters span turns in normal sessions).

**Replay vs. genuine context — two different things this spec must not conflate:**

- *Copied cumulative history:* a child counter initialized with (or re-emitting) the parent's accumulated totals. Counting this again is double counting. Must always be excluded.
- *Context actually sent in a new sub-agent request:* the replayed parent context is transmitted as input tokens of a real API call, typically billed at the **cached-input** rate. This may be genuine usage.

Which of these `last_token_usage` represents on a sub-agent's first turn in Ultra logs is an **empirical question** (§8). Phase 1 takes the conservative-for-inflation stance: after latch, `last` is capped by the contained totals delta (so below-watermark `last` is dropped). Phase 2 revisits this against the fixture.

## 3. Root cause

`CostUsageScanner` assumes **one monotonic cumulative counter lineage per session file**. `handleTokenCount` (in `parseCodexFileCancellable`, `CostUsageScanner.swift`) keeps a single `rawTotalsBaseline` and computes totals-derived deltas as `max(0, current − baseline)` via `codexTotalDelta`.

With two interleaved lineages A and B in one file the event stream looks like:

```
A: total=100M   → delta 100M, baseline=100M
B: total=5M     → clamped to 0 (divergent fallback), baseline=5M   ← baseline lowered
A: total=101M   → delta = 101M − 5M = 96M                          ← gap recounted
B: total=6M     → clamped to 0, baseline=6M
A: total=102M   → delta = 102M − 6M = 96M                          ← gap recounted again
...
```

Every lineage flip recounts nearly the entire gap between the two counters. Hundreds of interleaved snapshots inflate ~268M real tokens into billions.

Exposure by path:

- **Resolved fork child path** (`handleTokenCount`, the `forkedFromId != nil` branch) runs totals-only — it deliberately ignores `last` to avoid replayed per-turn snapshots (`45b68c34`). Worst offender; matches "a single forked turn contributed 3B+".
- **Total-only events** (no `last_token_usage`) hit the same gap-recount mechanism.
- **Root sessions with `last` present** degrade differently: the divergent flag disables the #1062 guard (`codexShouldPreferTotalDelta`), so re-emitted snapshots can re-count `last`.

Existing mitigations do not cover this failure mode:

| Mitigation | Covers | Gap |
|---|---|---|
| #968 divergent totals (`codexDivergentTotalDelta`) | Counter *decreases* within one lineage → fall back to counted baseline | Lowers the effective baseline, so the *next* event of the larger lineage recounts the gap |
| #1062 (`codexShouldPreferTotalDelta`) | Repeated identical total snapshots re-adding `last` | Only active in the non-divergent path, and only compares adjacent totals; interleaving disables it and defeats adjacency (see §5.2) |
| Fork handling (`forked_from_id`, `CodexInheritedTotalsResolver`) | Separate child *files* replaying parent history | No concept of multiple lineages interleaved *inside one file* |

## 4. Goals / non-goals

**Goals (Phase 1)**

- **Never-inflates invariant:** for any input, tokens attributed from totals-derived deltas never exceed the maximum raw cumulative total observed in the file (fork-inheritance adjusted). No sequence of interleaved or re-emitted snapshots can multiply usage.
- Exact re-emissions of previously seen snapshots contribute zero — including **alternating** re-emissions across lineages (this is where rev 1 of this spec was broken; see §5.2).
- Fork-replayed parent history stays excluded (existing behavior preserved).
- Single-lineage files behave exactly as today; all existing #968/#1062/fork tests pass unchanged.
- Incremental (append-only) scans resume with all correctness-critical reducer state and produce byte-identical results to a full rescan; the optional seen-snapshot FIFO may be absent without affecting containment.
- Multi-lineage results are explicitly documented as a conservative estimate (undercount bias), not exact usage.

**Explicitly accepted Phase 1 limitation**

A smaller lineage growing beneath another lineage's watermark (e.g. 5M → 50M under a 100M watermark) contributes nothing in Phase 1, even when it supplies `last_token_usage`: the contained totals delta is zero, so `min(last, 0) = 0`. This is **normal Ultra behavior, not a rare edge case**, and it is the deliberate trade: undercounting bounded genuine usage beats multiplying it. Phase 2 (§7) exists to recover it.

**Non-goals**

- Per-sub-agent usage attribution/breakdown UI.
- Changing pricing, priority/Ultra cost splitting (`CostUsageScanner+CodexPriority.swift`), or non-Codex providers.
- Phase 2 candidate-run tracking (specified in outline only; separate PR).

## 5. Phase 1 design

All post-latch token-count accounting uses the shared tracker and delta helpers (§5.5), with correctness-critical state persisted for incremental scans (§5.6). Rules below are the shared policy, in precedence order.

### 5.1 High-watermark containment (load-bearing)

Track `rawTotalsWatermark`: the component-wise maximum of every raw cumulative total observed (after fork-inheritance adjustment).

- **Interleaving detection:** an event whose total has **any component strictly below** the corresponding watermark component latches `sawInterleavedTotals` for the file (persisted, permanent). Mixed movement (input ↓ while output ↑) cannot come from one monotonic counter, so "any component" is deliberate. Legitimate single-lineage resets (compaction, restart, corrupt log) also latch the flag; that is accepted — it converts a potential overcount into an undercount.
- **Never lower** the watermark or the baseline on detection.
- Once latched, totals-derived deltas use `codexContainedTotalDelta` (§5.3.1), not a lowerable per-event baseline. Lineage flips cannot re-count the high/low gap.

**Supersedes divergent mode:** once `sawInterleavedTotals` is latched, `codexDivergentTotalDelta` (whose counted-baseline fallback *is* the gap-recount mechanism) and `codexShouldPreferTotalDelta` are not consulted for this file. `sawDivergentTotals` continues to work unchanged for never-interleaved files and for fork-parent snapshot resolution.

### 5.2 Seen-snapshot suppression (optional precision)

Maintain `seenRawTotals`: a **bounded FIFO** (~64) of raw cumulative totals for best-effort exact re-emission suppression.

- Exact matches can short-circuit to zero before delta math.
- After post-latch containment (§5.3), eviction cannot inflate usage: a re-emitted below-watermark total has contained delta 0, so `min(last, 0) = 0`.
- Therefore the seen set is **not** load-bearing for correctness and must not gate incremental resume.

### 5.3 Counting rule in interleaved mode

For each token-count event once `sawInterleavedTotals` is latched and a `total` is present:

1. Optionally, total exactly matches `seenRawTotals` → count **0** (precision optimization; not required for correctness).
2. Compute the **contained totals delta** component-wise (§5.3.1).
3. If `last_token_usage` is present → `delta = min(adjustedLastDelta(last), containedTotalDelta)`.
4. Otherwise → `delta = containedTotalDelta`.

`last` alone must never increase counted usage when the contained totals delta is zero. Smaller-lineage genuine `last` below the watermark is an accepted Phase 1 undercount.

#### 5.3.1 Contained totals delta (not plain watermark delta)

Do **not** use plain `codexTotalDelta(from: watermark, …)` after latch — that breaks #968 “resume from counted baseline” (growth below the old raw watermark that still exceeds counted totals).

Use a dedicated helper, component-wise:

```
if current >= watermark {
    delta = max(0, current - max(watermark, counted))
} else {
    delta = max(0, current - counted)
}
```

This preserves counted-baseline recovery without allowing high/low lineage gaps to be recounted. Bound after latch:

`counted ≤ max(counted_when_latched, subsequent_watermark)` (and for totals-only streams, `counted ≤ max observed cumulative total`).

### 5.4 Fork children

- **Non-interleaved** resolved forks keep totals-only accounting (`45b68c34` / #1164). Do not apply a global `min(last, total)` cap there — established tests require totals-derived deltas that can exceed `last`.
- **After latch**, resolved forks use the same post-latch rule as root sessions (§5.3), including `min(adjustedLast, containedTotalDelta)`.
- **Unresolved forks** keep skip-first + `min(last, totalDelta)`; `unresolvedForkTotalWatermark` is a presence sentinel while the global tracker supplies the delta baseline.

### 5.5 Shared policy surface

`CodexTotalsTracker` (watermark + optional seen-set + latch) is shared. Post-latch delta policy (`codexContainedTotalDelta` / `codexPostLatchEventDelta`) must be applied by all three consumers:

1. root / non-fork parsing (`handleTokenCount`)
2. resolved-fork parsing (`handleTokenCount`)
3. parent snapshot accumulation (`CodexSnapshotAccumulator`)

Otherwise fork children can inherit baselines computed under a different policy.

### 5.6 Cache: persist correctness-critical state

`CostUsageFileUsage` gains:

- `lastRawTotalsWatermark: CostUsageCodexTotals?` (**required** for interleaved / divergent resume)
- `hasInterleavedTotals: Bool?` (**required** when watermark is present; partial XOR → full rescan)
- `seenRawTotals: [CostUsageCodexTotals]?` (**optional** precision only — missing must not force rescan)

**Invalidation:** regenerate `CodexParserHash`; clear `compatibleCodexProducerKeys`. Legacy divergent entries without a watermark force a per-file full rescan.

## 6. Acceptance criteria

1. **Exact expectations (primary):** fixtures assert exact counted totals / row counts for each rule branch.
2. **Never-inflates property (merge bar):** generated totals-only interleaved sequences satisfy `counted ≤ max observed cumulative total`.
3. **Floor:** fixtures assert a conservative minimum so a degenerate ~0 parser fails.
4. **Manual / real Ultra log:** no multiplied-gap inflation; satisfies the formal containment bound; above the fixture's conservative floor; plausible relative to the raw log — **not** required to land “near” 268M, because Phase 1 intentionally drops smaller-lineage usage.

## 7. Phase 2 outline (separate PR, fixture-gated)

Recover totals-only / below-watermark smaller-lineage usage with candidate-baseline run tracking, gated on a sanitized real Ultra fixture that establishes `last_token_usage` semantics.

## 8. Prerequisite: sanitized real Ultra fixture

Needed before claiming accurate multi-lineage recovery (Phase 2). Phase 1 ships on synthetic fixtures plus the containment property.

## 9. Touched files

| File | Change |
|---|---|
| `CostUsageScanner.swift` | `codexContainedTotalDelta` / `codexPostLatchEventDelta`; tracker + accumulator; post-latch policy in all three consumers |
| `CostUsageScanner+CacheHelpers.swift` | Persist watermark + interleaved flag; seen-set optional; incomplete-state rescan |
| `CostUsageCache.swift` | New fields; clear compatible producer keys |
| `CodexParserHash.generated.swift` | Regenerated |
| `CostUsageScannerBreakdownTests.swift` | Containment / cap / eviction / cache / property tests |
| `docs/issue-2037-ultra-fork-overcount-spec.md` | This spec |

## 10. Test plan (merge bar)

1. `codex interleaved cumulative lineages do not recount the gap`
2. `codex alternating repeated snapshots count zero` — containment (not FIFO) keeps repeats at zero
3. `codex totals only growth below watermark is conservatively dropped`
4. `codex single lineage counter reset undercounts but never inflates` — preserves #968-style recovery past the peak
5. `codex interleaved fork child caps last by contained total delta`
6. `codex root interleaved caps last much larger than watermark delta`
7. `codex fork interleaved caps last much larger than watermark delta`
8. `codex interleaved replay after sixty five unique snapshots stays contained`
9. `codex interleaved totals only sequences stay within containment bound` (property)
10. `codex incremental append preserves interleave containment across boundary` — full state equality vs forceRescan
11. `codex missing watermark or interleaved flag forces full rescan`
12. `codex missing optional seen set keeps incremental resume safe`
13. `codex divergent cache entry without watermark forces full rescan`
14. Existing `#968` / `#1062` / fork replay tests unchanged

Regression: `make check`, focused scanner tests, then `make test`.

---

# PR documentation (draft body — Phase 1)

## Title

Contain Ultra-mode interleaved-lineage token overcounting (#2037)

## Summary

- Ultra-mode Terra/Sol sessions can interleave cumulative `total_token_usage` snapshots from multiple lineages in one JSONL file. A single file-global baseline then recounts the high/low gap on every flip — turning ~268M real input tokens into ~3.29B (~$4,000) in a reported session.
- Phase 1 makes inflation **provably bounded**: a never-lower watermark latches interleaved mode on any component drop; post-latch deltas use a dedicated containment helper (preserving #968 counted-baseline recovery) and `min(adjustedLast, containedTotalDelta)` so `last` cannot grow usage when the contained totals delta is zero.
- **Single-lineage and pre-latch fork behavior is preserved** (including #1164 totals-only fork replay handling). The slow JSON path and fork-parent snapshot builder share the same policy.
- Cache persists watermark + interleaved flag (`seenRawTotals` is optional precision only); incomplete critical state forces a full rescan. Parser hash invalidation rebuilds old caches once.
- **Smaller-lineage undercount is intentional** and deferred to fixture-gated Phase 2. Latched files are a conservative estimate, not claimed true per-lineage usage.

Fixes #2037. Related: #968, #1062, `45b68c34` (fork replay).

## Behavior changes

- Interleaved (Ultra) files: no multiplied-gap inflation; after latch, counted totals stay within the containment bound and `last` cannot exceed the contained totals delta.
- Single-lineage / never-latched files: unchanged counting semantics.
- Pre-latch resolved forks: still totals-only (replay-safe).
- Post-latch: below-watermark smaller-lineage usage may be dropped until Phase 2.

## Test plan

- [x] Focused `CostUsageScannerBreakdownTests` / `CostUsageCacheTests` (containment, caps, eviction, property bound, cache gates)
- [x] Existing #968 / #1062 / fork replay tests
- [x] `make check`
- [ ] `make test`
- [ ] Optional follow-up: rescan a real Sol/Ultra log for plausibility (not a merge blocker)

## Notes for reviewers

- Design is lineage-ID-free; value-based multi-run recovery is Phase 2 behind a sanitized Ultra fixture.
- `seenRawTotals` is **not** load-bearing after the post-latch min-cap; missing it must not force a rescan.
- A real Ultra log is valuable validation, not required to merge Phase 1 containment.
