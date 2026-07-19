# P0 local corpus findings for #2037 (rev 2)

- **Source:** local Codex JSONL under `~/.codex/sessions` + `~/.codex/archived_sessions` (this machine)
- **Date:** 2026-07-11 (rev 2 adds scanner-integration observations)
- **Scope:** structural identity / fork-copy behavior only — no message bodies; session IDs truncated in narrative
- **Status:** Provisional locks for Codex rollout logs on this corpus. Still need an Ultra-shaped golden to close #2037, but ordinary-fork identity + parent-present scanner behavior are locked in-repo.
- **Companion:** `docs/issue-2037-fork-family-provenance-spec.md` (rev 8a+)

## Corpus snapshot

| Metric | Value |
|--------|-------|
| JSONL files | ~81+ (grew during Ultra P0 attempts) |
| Logical sessions (first `session_meta.id`) | dozens |
| Real fork edges (`forked_from_id` ≠ self) | several families |
| `token_count` events surveyed | ~6k+ |

Observed families (prefixes):

- `019f33ce` → `019f3869` → `019f38ec` (parent → child → grandchild)
- `019f32c8` → `019f331e` (mid-session / partial prefix fork)
- `019f3cec` → `019f3e32` (partial prefix; parent continued after fork)
- Later Ultra-adjacent: `019f4d90` → `019f52bf` / `019f52e6` / `019f52e7` / `019f52f3` (Sol/Terra, multi-agent v2)

## Locked answers (local Codex)

### §10.1 Event-key cardinality

| Candidate | Survives copy? | Event-level cardinality? | Verdict |
|-----------|----------------|--------------------------|---------|
| Stable event / request / message ID on `token_count` | n/a | **Absent** on `token_count` rows | Do **not** use as event key |
| `turn_id` | Present on other events (`event_msg`, `turn_context`) | **Not** on `token_count` | Lineage / priority join hint only — never sole cross-completion key |
| Envelope `timestamp` on `token_count` | **No** — rewritten at fork into a tight burst | n/a | **Not** copy-stable; exclude from fingerprint match |
| File-local ordinal / line number | No | Tie-break only | Exclude from fingerprint |
| Normalized `last_token_usage` + `total_token_usage` vector | **Yes** (field-equal, ordered) | Unique within observed parent streams, but not proven unique across distinct sibling work | Copy-candidate evidence only; insufficient destructive event identity |
| Byte-identical JSONL line | **No** (0 byte-identical parent↔child lines) | n/a | Prefer normalized equality |

**Lock:** For this Codex shape, there is **no** stable per-`token_count` event ID. Ordered exact-prefix matching of normalized usage vectors under `forked_from_id` ancestry identifies the copied-prefix candidate in the sanitized corpus, but token equality alone must not suppress runtime billing.

### §10.2 Copy equality

Copied ancestor `token_count` rows are **field-equal after normalization**, not byte-identical. Matching inputs that worked locally:

- `last_token_usage` (all int fields)
- `total_token_usage` (all int fields)

Do not require equal timestamps.

### §10.9 Fork-boundary rule (locked for this corpus)

**Corpus oracle rule (not a sufficient runtime event key):** Contiguous ordered usage-fingerprint prefix.

1. Take parent and child canonical `token_count` streams in file order.
2. Let `N` = longest `k` such that `child[0..k)` equals `parent[0..k)` under the normalized usage fingerprint.
3. `child[0..N)` is the copied prefix (state-only on the child; parent owns billing when present).
4. `child[N..)` is child-local work.

**Corroboration (not the classifier):** leaf `session_meta.timestamp` (`fork_ts`) lands within ~0–1s of the end of the rewritten prefix / start of unique work on observed mid-session forks. Useful for family graph ordering; **do not** classify prefix via `parentEventTimestamp <= fork_ts` because copied child timestamps are rewritten and are **not** the parent’s original times.

**Evidence:**

| Edge | Parent `token_count`s | Child | Prefix `N` | Parent continued after fork? |
|------|----------------------|-------|------------|------------------------------|
| `33ce→3869` | 135 | 158 | 135 (entire parent) | No |
| `3869→38ec` | 158 | 158 | 158 (entire parent; no unique child tokens in archive) | n/a |
| `32c8→331e` | 270 | 276 | 243 | Yes (+27 parent events) |
| `3cec→3e32` | 387 | 581 | 226 | Yes |
| `4d90→52bf` | 293 (live; continued) | 196 | 180 | Yes (parent continued after copy) |

### §10.4 `last_token_usage` semantics

On ordinary in-session streams, `Δ total_token_usage.total_tokens == last_token_usage.total_tokens` on nearly every step (hundreds of matches, ~0 positive mismatches in sampled files).

**Caveat:** the first post-fork child event can show `last > 0` while `total` is still flat vs the last prefix event. After provenance, billing should follow the corpus-locked per-event policy carefully; total-delta alone undercounts that row, last alone may overcount vs cumulative. Flag for golden oracles — do not invent a hybrid in P0 prose beyond “measure on goldens.”

**Oracle units:** hand oracles that sum `last.total_tokens` are **not** identical to scanner-priced units. Scanner accumulates `input + cached_input + output` from each billed delta. Integration tests must compare **scanner units** (`sum(last.input+cached+output)` with prefix suppressed), not raw `total_tokens` field sums.

### §10.5 / ownership migration

- Authoritative session identity for a file: **first** `session_meta` in the file (the leaf). Later `session_meta` rows often re-embed ancestors.
- Child / grandchild files embed ancestor `session_meta` chains (`leaf`, then parent, then grandparent, …). Graph builder must not treat every embedded meta as a separate root file identity.
- Filename UUID can differ from leaf `session_meta.id` only in the sense that archives are named by leaf id; always prefer leaf meta id.
- Parent may continue after a child forks (partial prefix). Billing of copied keys stays with the earliest real ancestor that contains them; child baseline still walks the actual parent chain (spec §4.5.1).

### §10.7 Same-session multi-file

Common: active `sessions/…` rollout + `archived_sessions/…` for related rollouts. Same-session union must be **ordered overlap**, not unordered fingerprint sets. Multi-file groups often share a leaf id across rollouts; treat carefully (some “same id” groups are true active/archive; some are chained fork archives — use first `session_meta` + `forked_from_id`).

### Inflation demo (one family)

For `019f33ce` + child `019f3869`, summing `last_token_usage.total_tokens` over both files without prefix dedupe vs parent-owns-prefix:

| Method | Sum of `last.total_tokens` |
|--------|----------------------------|
| Naive parent+child | ~28.8M |
| Dedupe (parent owns prefix) | ~15.4M |
| Inflation ratio | ~1.88× |

This is the inter-file overcount shape on ordinary forks (not yet Ultra interleave).

## Ultra / interleaved hunt (observations)

Attempts to produce **intra-file interleaved cumulative streams** (multiple rising `total_token_usage` counters mixed so totals **drop** mid-file):

| Attempt | What appeared | Total drops ≥50k? |
|---------|---------------|-------------------|
| Sol/Terra + multi-agent v2 forks (`4d90` family) | Fork copies, monotonic totals | **No** |
| Parallel-worker P0 prompt (fixture sanitization) | New forks `52e6`/`52e7`/`52f3`, proactive mode sometimes | **No** |
| Corpus-wide scan after those runs | — | **0 files** |

**Conclusion:** Harder tasks and parallel Ultra workers on this Codex build produced useful **fork-copy** logs and Sol/Terra multi-agent metadata, but **not** the reporter’s interleaved gap-recount shape. Token drops are **not** required to proceed on cross-file provenance. Interleaved Ultra remains reporter-corpus-dependent.

“Ultra” string hits in older logs were mostly chat/tool text / schemas, not a structural Ultra mode flag on `token_count`.

## What local data does *not* yet prove

- Ultra interleaved multi-lineage totals inside one file (the #2037 reporter shape / billions-scale gap)
- Priority / `logs_2` turn surcharge metadata on these `token_count` rows (not visible in the JSONL token payload here)
- Copy-stable event identity for parent-missing siblings; the added fixture proves the arithmetic gap, not that token-vector equality is collision-free
- Cross-session / cross-sibling `usage_fp` collision rate at scale (sample showed collisions across parent/child as expected; token equality is not allowed to become destructive identity)

## P1 design constraints from the provisional corpus

1. **Event key:** none from explicit IDs on `token_count`.
2. **Copy candidate:** ordered contiguous normalized `(last_token_usage, total_token_usage)` under ancestry.
3. **Fork-boundary oracle:** that contiguous prefix length `N`; `session_meta` fork timestamp for graph ordering only.
4. **Low-confidence fingerprint:** usage vectors exclude rewritten timestamps and file ordinals, but cannot drive suppression without stronger copy-stable identity.
5. **Future billable owner:** earliest real ancestor containing a ledger-accepted copied event; descendants state-only only after identity acceptance.
6. **Embedded meta:** first `session_meta` is leaf; ignore ancestor meta rows as competing file identities.
7. **Runtime today:** fail open for missing-parent cross-file equality; `#2066` containment remains file-local and non-closing.

## In-repo fixtures and tests (what we built)

| Path | Role |
|------|------|
| `Tests/.../Fixtures/CostUsage/Issue2037/archived-fork-33ce-3869/` | Sanitized parent+child from local `33ce→3869`; usage+meta only |
| `.../live-fork-4d90-52bf/` | Second parent-present golden from `4d90→52bf`; parent truncated to prefix N=180 |
| `.../missing-parent-siblings/` | Two children, shared prefix, no parent file |
| `.../ORACLE.md` + `manifest.json` | Hand oracle: naive vs parent-owns-prefix / provisional owner |
| `.../harness-smoke/` | Tiny install harness smoke |
| `Issue2037FixtureSupport.swift` | Shared load/install + sanitized event parsing |
| `Issue2037ProvenanceFixtureTests.swift` | Prefix length, oracle arithmetic, field allowlist |
| `Issue2037FixtureHarnessTests.swift` | Install into `CostUsageTestEnvironment` |
| `Issue2037ScannerIntegrationTests.swift` | End-to-end `loadDailyReport` vs scanner-unit oracle |

Fixture timestamps were rewritten to **midday UTC** on distinct calendar days so local timezones do not map parent rows outside a Jan 1–2 report window (midnight UTC previously made parent appear as the prior local day and dropped it from the report).

## Scanner integration observations (2026-07-11)

### Experiment

1. Install `archived-fork-33ce-3869` into an isolated Codex home (`sessions/` + `archived_sessions/` roots as the scanner expects).
2. `CostUsageScanner.loadDailyReport(provider: .codex, …, forceRescan: true)` over the fixture days.
3. Compare scanned `input + cacheRead + output` to:
   - **naive scanner units:** sum of `last.input+cached+output` over parent **and** all child events
   - **deduped scanner units:** parent all events + child events after prefix N only

### Result

**With the parent file present in-window, current `#1164` inherited-totals accounting already matches the parent-owns-prefix scanner-unit oracle.**

- Child absolute totals are rebased by the parent snapshot at/before fork.
- Copied prefix therefore contributes ~0 on the child; unique suffix bills the post-fork growth.
- Parent bills its own stream once.
- `Issue2037ScannerIntegrationTests` locks this as a **regression**, not as a new ledger.

### Pitfalls discovered while integrating

1. **Timezone / day-key:** UTC midnight timestamps can fall on the previous **local** calendar day; a narrow `since/until` then silently omits the parent and the report shows only child unique growth (~3.3M in one probe) — looking like undercount, not overcount.
2. **Oracle unit mismatch:** `sum(last.total_tokens)` ≠ scanner priced units when `total_tokens` omits cached input; always compare scanner units in integration tests.
3. **Filename date filter:** flat `archived_sessions` listing allows undated names (`parent.jsonl`); dated filenames are range-filtered — fine for fixtures without dates in the name.

### What `#1164` does *not* cover (next work)

| Gap | Why inheritance is insufficient |
|-----|----------------------------------|
| **Missing parent** + two siblings sharing a copied prefix | No parent snapshot to inherit; each child can bill the full prefix |
| **Provisional family** billable owner | Spec §4.4.2 / §4.5.1 — needs family ledger, not per-file baseline alone |
| **Intra-file interleaved totals** | No drops in local Ultra logs; containment (#2066) is a separate guard |
| **True event-key ledger** across arbitrary ancestry depth | Inheritance is fork-point baseline, not per-event ownership migration |

## Method notes

Repro probes were ephemeral Python over `~/.codex/**/*.jsonl`, hashing normalized usage vectors and comparing ordered prefixes. Raw production JSONL was not copied into the repo; fixtures are sanitized aliases only.

## Next steps

1. ~~Add a **missing-parent sibling** sanitized fixture + hand oracle that exposes today’s `#1164`-only gap.~~ **Done** (`missing-parent-siblings`). Runtime cross-file suppression is deferred until copy-stable event identity is proven.
2. ~~Optionally sanitize `4d90→52bf` as a second parent-present golden.~~ **Done** (`live-fork-4d90-52bf`; parent truncated to copied prefix for a clean `#1164` regression). Locks a real corpus quirk: parent ordinal 120 has non-zero `last` with flat `total` — scanner units must follow **total deltas**, not `sum(last)`.
3. Still seek an Ultra interleaved corpus before claiming #2037 fully closed for that shape.
4. Build the event-key ledger / ownership migration path (including parent disappear/reappear) before enabling missing-parent cross-file dedupe.
5. PR packaging: keep #2066 non-closing; ship containment + provenance fixtures/docs without claiming full #2037 close.

### Missing-parent siblings (fixture locked; runtime dedupe deferred 2026-07-12)

Fixture `missing-parent-siblings`: two children, shared 135-event prefix, no parent file.

| Metric | Scanner units |
|--------|---------------|
| Naive (both bill prefix) | ~54.4M |
| Target parent-owns-prefix oracle | ~28.8M |

The provisional token-vector prefix suppression was removed before merge. Distinct sibling events can have identical `last_token_usage` / `total_token_usage` vectors at the same ordinal; treating that equality as event identity can silently suppress legitimate work. Adding envelope timestamps is invalid because copied timestamps are rewritten, and model is not reliably present on `token_count` rows.

**Runtime fail-open rule:** when a parent file is missing, do not perform destructive cross-file dedupe from token counters alone. Each sibling keeps its file-local unresolved-parent accounting. This can retain copied-prefix overcount, but it cannot undercount distinct work merely because counters collide. `Issue2037ScannerIntegrationTests` locks this with two missing-parent siblings whose distinct models/timestamps have equal token vectors.

The sanitized fixture and arithmetic remain useful as the desired family-ledger oracle. They do not authorize suppression until the runtime has a corpus-proven copy-stable event key, collision handling, cross-window family closure, and an exposed ambiguous/contained quality path.

**Required before revisiting runtime suppression:**
- Prove a copy-stable identity stronger than token values; `reasoning_output_tokens` / `total_tokens` only reduce collision probability and are not sufficient identity.
- Build family closure across files outside the reporting window before applying the date filter.
- Add fingerprint-collision, ownership migration, cache-repeat, and affected-setup proof.
