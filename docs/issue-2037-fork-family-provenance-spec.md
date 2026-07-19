# Spec: Scan-wide fork-family event provenance for Ultra overcounting (issue #2037)

- **Issue:** [steipete/CodexBar#2037](https://github.com/steipete/CodexBar/issues/2037) — Ultra / forked-session token overcounting
- **Status:** Proposed (architecture redesign; fixture-gated) — rev 8a
- **P0 local corpus:** `docs/issue-2037-p0-local-corpus-findings.md` (provisional Codex locks from `~/.codex` forks; Ultra golden still open)
- **Supersedes as the canonical fix:** file-local-only approaches for closing #2037, including claiming [#2066](https://github.com/steipete/CodexBar/pull/2066) as a full fix
- **Related:** [#2066](https://github.com/steipete/CodexBar/pull/2066) (Codex intra-file containment — interim / non-closing at best), [#2043](https://github.com/steipete/CodexBar/pull/2043) / [#2059](https://github.com/steipete/CodexBar/pull/2059) (Pi file-local reconciliation merged then reverted), #968, #1062, #1164 / `45b68c34`
- **Affected code (expected):** `Sources/CodexBarCore/Vendored/CostUsage/` (Codex first); Pi only if the sanitized corpus proves the same shape

## 0. Framing (read first)

After [#2059](https://github.com/steipete/CodexBar/pull/2059), the repository owner retained #2037 as the canonical tracker. A replacement must provide:

1. **Cross-file fork-family / stable event provenance** — copied ancestor events across related fork files must not be charged once per file.
2. **Proof against a sanitized real fork corpus** — exact tokens and nonlinear pricing, not synthetic-only confidence.

[#2043](https://github.com/steipete/CodexBar/pull/2043) showed three failure modes to avoid:

- copied ancestor rows across fork files still duplicated
- distinct events collapsed under a shared lineage key
- cumulative→delta conversion priced without full nonlinear context

This document is the **canonical redesign**. The sanitized corpus is **design input**, not only final QA (§10): the exact provenance key cannot be chosen responsibly until the logs answer which IDs survive copies. If logs contain no usable stable identity, an exact solution may be impossible and the product must ship an explicitly labeled conservative estimate (`accountingQuality = contained`, §6).

**Identity contract (summary):** use an ID as an event key only when the corpus proves **event-level cardinality**; request/message-scoped IDs that cover several snapshots need a copy-stable compound sequence or remain lineage hints. Otherwise use an exact pre-fork copied prefix under ancestry and a corpus-locked fork-boundary rule; never token-only dedupe; preserve post-fork distinct events; ambiguous or invalid graph states → no aggressive merge (§5). Fingerprint inputs must be copy-stable (§7); file-local ordinal is a tie-break only, not a fingerprint field unless the corpus proves it survives copying.

**P1 vs P2 boundary:**

| Phase | In scope | Out of scope |
|-------|----------|--------------|
| **P1** | Same-session union → cross-window family closure → normalize events (incl. priority metadata) → deterministic family/provisional graph → provenance ledger + ownership/baseline continuity → corpus-proven per-event accounting → per-event pricing → two-tier atomic family cache → quality fields/reasons to report/UI | Per-lineage cumulative baselines as primary accounting; closing #2037 when any affected golden needs containment |
| **P2** | Per-lineage baselines on unique events; demote watermark min-cap to ambiguous-only fallback | — |

**Closing #2037:** P1 may close the issue **only if** the sanitized corpus proves the P1 per-event accounting path **and** no affected golden family requires the containment fallback (`accountingQuality = contained`). `provenanceQuality = incomplete` alone does not block closure when a corpus-locked provisional-family rule produces `accountingQuality = primary` and matches the hand token/cost oracle over the available corpus. If any in-scope golden still needs containment (or event/lineage identity remains unproven), **P2 is required** before closing; P1 can still ship as a non-closing step with #2037 left open.

**Relationship to [#2066](https://github.com/steipete/CodexBar/pull/2066):** file-local watermark + min-cap is a **conservative fallback only** when lineage identity is genuinely ambiguous — never the primary method, never sufficient alone to close #2037.

## 1. Problem (two layers)

### 1.1 Inter-file — copied ancestor events (owner-canonical)

Fork children can embed or re-emit ancestor `token_count` history in separate JSONL files. Today each file is scanned largely independently:

- `forked_from_id` + inherited cumulative baseline (#1164) helps when the child only exposes high `total_token_usage`
- it does **not** recognize the same ancestor event copied into another session
- `CodexUsageRow` keeps only `turnID` and a session-local `eventIndex` (plus day/model/tokens). That is insufficient for cross-file provenance

Result: the same completion can be charged once per file that carries a copy.

### 1.2 Intra-file — interleaved cumulative lineages

Ultra-style sessions can interleave multiple monotonic `total_token_usage` sequences in one file. A single global baseline recounts the high/low gap (see `docs/issue-2037-ultra-fork-overcount-spec.md`). Real, but not sufficient alone for §0.

### 1.3 Non-goals (first redesign PR)

- Per-sub-agent breakdown UI
- Changing models.dev / priority rate tables
- Claiming OpenAI invoice parity
- Closing #2037 without corpus-locked keys and golden totals

## 2. Definitions

| Term | Meaning |
|------|---------|
| **Normalized raw event** | Lossless extraction of one log `token_count` (and related ids/metadata) before accounting (§4.2) |
| **Same-session union** | Build a provenance-safe union of active + archived views of the **same** `sessionId` before cross-session family work (§4.1) |
| **Fork family** | All sessions descending from the same root under `forked_from_id` ancestry; one reconciliation unit |
| **Provisional family** | Children sharing the same unavailable `forked_from_id`, grouped under a synthetic missing-parent node (§4.4) |
| **Fork boundary** | The single P0 corpus-locked rule that separates copied ancestor prefix from child-local work (§4.3.1) |
| **Copied prefix** | Ancestor events that appear in a descendant file before that child’s fork boundary |
| **Event key** | Stable identity for recognizing the same source event across family files |
| **Lineage** | Real task/agent/turn cumulative sequence *after* family dedupe — only if the fixture shows a reliable id (P2 primary) |
| **Family ledger** | Accepted event keys for a family (count once across the entire family) |
| **Billing disposition** | Whether an observed event emits tokens/cost (`accepted`) or is a copied duplicate (`duplicate`) |
| **State disposition** | Whether an observed cumulative snapshot seeds or advances lineage state even when it is non-billable (§4.6) |
| **Billable owner** | The single family occurrence allowed to emit tokens/cost for one accepted event key (§4.5.1) |
| **Quality** | Independent provenance + accounting trust signals (§6); not a single overloaded enum |

## 3. Pipeline (explicit order)

Conceptual orthogonality of “same-session archive dedupe” vs “cross-session fork dedupe” is true; **the pipeline must still order them**.

```mermaid
flowchart TD
  enum[Metadata index / family closure]
  same[Union same-session active/archive views]
  extract[Extract normalized raw events per canonical session]
  graph[Build fork-family graph + validate graph]
  prov[Resolve event provenance across the family]
  lineage[Account: P1 passthrough / P2 per-lineage]
  price[Price each unique event individually]
  quality[Assign provenanceQuality + accountingQuality]
  cache[Replace family contribution atomically]
  window[Filter accepted events to requested report window]
  report[Propagate quality fields into CostUsage report / UI]

  enum --> same --> extract --> graph --> prov --> lineage --> price --> quality --> cache --> window --> report
```

**Ordering rules:**

1. **Metadata closure first.** Enumerate/index enough metadata to identify relevant family membership, including out-of-window ancestors (§4.3).
2. **Then same-session union.** Build a provenance-safe union of active/archive views so one logical session contributes one normalized event stream before it participates in a fork family. Preserve unique suffixes; do not build families from duplicate extractions of the same `sessionId`.
3. **Then cross-session families.** Provenance ledger operates on canonical logical sessions only.
4. **Provenance before accounting.** Dedupe copies before lineage baselines or containment fallback.
5. **Price after reconciliation.** Nonlinear-safe.
6. **Quality after pricing inputs are known** — set **independent** provenance and accounting quality fields (§6), then persist with the family contribution.
7. **Report window last.** Reconcile the relevant family closure before filtering accepted events to `scanSince` / `scanUntil` (§4.3).

### 3.1 Normative invariants

1. **Once per key:** one accepted family event key has exactly one billable owner.
2. **Owner priority:** real ancestor occurrence before provisional sibling representative; ownership migration never bills both.
3. **State continuity:** copied/non-billable observations may seed or advance raw cumulative state but never increase `countedTotals`.
4. **Remove monotonicity:** removing a family file never increases attributed tokens/cost.
5. **Restore stability:** restoring a parent never increases the contribution of already-known copied keys; total may rise only for newly discovered unique events.
6. **Scan equivalence:** warm incremental = cold cache = force rescan for tokens, rows, costs, graph, ownership, and quality reasons.
7. **Window after reconcile:** out-of-window ancestors may seed/dedupe, but accepted usage is bucketed only by original event time.
8. **Event-local dates:** pricing date and report day derive from the original event timestamp — never scan, cache, restoration, or fork processing time.

## 4. Design steps

### 4.1 Union same-session active/archive views

Before constructing cross-session fork families:

- Identify files that share a `sessionId` (active partial + archived rollout, etc.).
- Merge their normalized events into one **canonical logical-session stream** using a local ordered-view rule; do not wait for fork-family construction (same-session views have no ancestry edge).
- Prefer namespaced event keys when event-level cardinality is corpus-proven. Otherwise align copy-stable normalized events within this `sessionId` only, preserving order and occurrence multiplicity (ordered prefix/overlap matching, not an unordered fingerprint set).
- Preserve unique events from every view (for example an archived suffix missing from an active partial file) while suppressing copied rows.
- Two legitimate identical occurrences remain two events when their ordered positions/multiplicity show both are present; fingerprint equality alone must not collapse them.
- Remember every source path and digest for invalidation, but emit only the merged logical stream into the family graph.
- Conflicting parent metadata across views of the same `sessionId` is an invalid state (§4.4), not a reason to pick whichever file was enumerated first.

This is a **hard prerequisite step**, not an afterthought.

### 4.2 Extract normalized raw usage events

Each token event should retain at least:

| Field | Role |
|-------|------|
| Session ID | Owning canonical session |
| Parent session ID | `forked_from_id` when present |
| Fork timestamp | Family ordering + pre-fork copy window |
| Stable event / request / message ID | Candidate provenance key only after corpus proof of event-level cardinality; namespace by ID kind |
| Turn ID | Attribution / priority join / optional lineage hint — **never** sole cross-completion key |
| Original event timestamp | Ordering + fingerprint |
| Ordinal within file | **Tie-break only** when timestamps collide — **not** a fingerprint input unless the corpus proves ordinals survive copying (insertions shift them) |
| Model and pricing date | Nonlinear / dated pricing |
| Raw `last_token_usage` | Per-event signal (semantics TBD by corpus) |
| Raw `total_token_usage` | Cumulative validation / lineage-local fallback |
| Canonical fingerprint of the source event | Fallback identity when explicit IDs are absent (§7); must use **copy-stable** fields only |
| **Priority / turn metadata** | Enough to reproduce standard vs priority pricing (`logs_2` / turn priority flags, surcharge eligibility, etc.) |

**Priority metadata must survive normalization** so per-event pricing can split standard vs priority totals the way today’s priority overlay expects. Dropping it and re-deriving only from aggregates is a #2043-class pricing footgun.

**Why:** today’s `CodexUsageRow` is too lossy for cross-file provenance and for faithful per-event pricing.

### 4.3 Build a fork-family graph

```text
root session
├── child A
│   └── grandchild
└── child B
```

All sessions descending from the same root are **one reconciliation unit**. Process parent-before-child when the graph is a DAG.

**Family closure precedes date filtering.** Build or refresh a lightweight metadata index (session ID, parent ID, fork timestamp, source paths, coarse event date range) across all relevant roots/cache entries. For any session that can contribute to the requested report, load the transitive family members and the ancestor events required to establish provenance and cumulative baselines even when those files or events fall outside the report window. Reconcile first, assign accepted usage to each event's original date, then apply `scanSince` / `scanUntil`. An out-of-window parent must not become an artificial “missing parent” merely because the report window starts later.

#### 4.3.1 Corpus-locked fork boundary

The fork boundary is normative provenance input, not a heuristic chosen independently by each parser path. P0 must select and document one corpus-proven rule, for example:

- the child rollout/session metadata fork timestamp
- the final event in a proven shared copied prefix
- the first child-local event after that shared prefix
- another explicit field established by the sanitized corpus

The selected rule becomes part of the parser/reconciliation fingerprint. A parent event is prefix-eligible only when it satisfies that locked rule (for timestamp rules, normally `parentEventTimestamp <= boundary`). If the boundary is missing, contradictory, or cannot distinguish copied prefix from post-fork work, do not guess aggressively: record `ambiguousForkBoundary`, set `provenanceQuality = incomplete`, and use the corpus-defined conservative path (`accountingQuality = contained` when containment is required).

### 4.4 Invalid / ambiguous family states

Treat the following as **invalid or ambiguous** (no aggressive fingerprint merge; `provenanceQuality ≠ complete`, and often undercount-preferring):

| Condition | Handling |
|-----------|----------|
| **Cycle** in `forked_from_id` edges | Apply the normative timestamp-first forest algorithm below; reject cycle-closing edges; set `provenanceQuality = incomplete` |
| **Conflicting parent claims** | Two authoritative views/files for one logical `sessionId` claim different parents, or authoritative session metadata disagrees with another authoritative parent-edge source → accept no guessed parent edge; record `conflictingParents`; set `provenanceQuality = incomplete`. Non-authoritative inference must not create an edge. The cycle/forest algorithm runs only after each session has at most one accepted parent candidate |
| **Stable-ID collisions** | Same namespaced ID maps to multiple token events without a corpus-proven compound sequence, or maps to incompatible payloads → the ID is not event-unique; keep the events separate, set `provenanceQuality = incomplete`, and never silently overwrite or arbitrarily drop one |
| **Missing parent** | Group all children sharing the unresolved parent ID under one provisional family node; apply the deterministic policy below; set `provenanceQuality = incomplete` |

#### 4.4.1 Deterministic DAG / cycle rule

For each connected component, build the accepted forest from the complete currently known edge set — never from file enumeration order:

1. Parse fork timestamps. Valid timestamps sort before missing/invalid timestamps.
2. Sort edges by `(timestampValidity, forkTimestamp ascending, childSessionId, parentSessionId)`.
3. Add edges in that order. Reject an edge if adding it would create a cycle.
4. Mark every component with a rejected edge `provenanceQuality = incomplete` and record `cycleBroken` when quality reasons are persisted.
5. Recompute the whole connected component whenever an edge/member changes; a warm incremental scan and a full rescan must produce the same accepted forest.

This prioritizes the earliest physically reported fork relation while retaining session IDs as stable tie-breakers when timestamps are equal or unusable.

#### 4.4.2 Missing-parent provisional family

A missing parent ID is still relationship evidence. Create a synthetic node keyed by `missing:<parentSessionId>` and attach all children that reference it.

- Reconcile corpus-proven stable event keys shared by those siblings.
- When explicit IDs are unavailable, apply a sibling exact-prefix rule only if the sanitized fixture locks copy-stable equality and the events are pre-fork for every affected child.
- If the pre-fork streams remain ambiguous, choose one deterministic canonical pre-fork stream `(valid forkTimestamp first, earliest timestamp, sessionId)` as the billable representative; other sibling pre-fork streams are state-only. Set `accountingQuality = contained`.
- Post-fork events remain separate unless a proven event key establishes an actual copy.
- If a formerly present parent disappears, recompute the family under this provisional rule and atomically replace its old contribution.
- If the real parent later appears, dissolve `missing:<parentSessionId>`, rebuild the real family from all member views, migrate copied-key ownership to the real ancestor, and atomically replace the provisional and any old sibling-local contributions. Newly discovered unique parent events may add cost; already-known copied keys may not.

**File-removal monotonicity invariant:** removing a file from the available family corpus must never increase the family's attributed tokens or cost. It may stay equal (copied parent history remains represented once) or decrease (unique events disappeared), but must not rise because siblings began double-charging a copied prefix.

Accounting quality for provisional families is determined by the identity path, not merely by the parent's absence:

| Sibling-prefix evidence | Accounting result |
|-------------------------|-------------------|
| Corpus-proven shared event keys or corpus-proven exact-prefix equality | `accountingQuality = primary`; record `missingParent` + `provisionalFamily` |
| Deterministic representative selected because streams disagree or identity/boundary is ambiguous | `accountingQuality = contained`; record `missingParent` + `provisionalFamily` + `containmentFallback` (and the relevant ambiguity reason) |

Thus `provenanceQuality = incomplete` does not imply containment by itself.

### 4.5 Resolve event provenance across the family

For every normalized event:

1. **Prefer a namespaced stable event / request / message ID only when the corpus proves event-level cardinality** as well as copy survival. If one request/message ID covers several token snapshots, compound it with a copy-stable event sequence/type proven by the corpus or treat it only as a lineage hint.
2. **Otherwise**, recognize an **exact copied prefix** only when:
   - the files have an ancestor relationship in the family graph, **and**
   - the event occurs **before the fork boundary** of the descendant, **and**
   - “exact” means corpus-defined equality: prefer byte-identical source lines when that holds; otherwise normalized equality of retained raw fields — pin from the fixture.
3. **Count a copied ancestor event once** across the entire family by assigning its billable owner under §4.5.1. The same proposed key with a different accounting payload is a collision, not a duplicate (§4.4).
4. **Never deduplicate merely because two events have the same token values.**
5. **Preserve identical-but-distinct events after the fork.**

**Tie-break:** `(timestamp, ordinal, session topological order)`.

**Forbidden:** token-only dedupe; file-local `eventIndex` as cross-file identity; shared Ultra/task id as the *only* key for many completions.

#### 4.5.1 Billable ownership (normative)

For each accepted family event key `K`, assign exactly one `billableOwner`:

1. **Real ancestor present and contains `K`:** the earliest real ancestor occurrence in parent-before-child order owns billing. Descendant occurrences are state-only duplicates.
2. **Real parent missing or does not contain `K`:** one deterministic provisional sibling occurrence owns billing (the canonical representative rule in §4.4.2). Other sibling occurrences are state-only duplicates.
3. **Partial parent:** apply the rule per key, not per whole prefix. Keys actually present in the parent are parent-owned; keys only visible in children use the provisional representative.
4. **Parent reappears:** recompute the family and migrate ownership for matching keys to the real ancestor in one cache generation. Never retain both the provisional and real owner.
5. **Conflicting payload for the same proposed key:** this is a collision, so no ownership merge occurs (§4.4 / §7).

Ownership changes where a row is sourced, not its semantic identity, original timestamp, token vector, or price. Therefore a copied key remains billed once across parent disappearance/reappearance transitions.

Billable ownership applies only to the contribution for `K`; it does not shortcut baseline propagation. If grandparent and parent both contain `K`, the grandparent owns billing, but the child still seeds state by walking its **actual parent chain** and applying each fork-boundary snapshot in order. Intervening unique parent events must advance the child baseline even when earlier copied keys are grandparent-owned.

Parent restoration may change `provenanceQuality` from incomplete to complete only after the full real family is recomputed and has no remaining missing edges, collisions, cycle breaks, or ambiguous fork boundaries. Corpus goldens prove that transition; runtime assigns it from recomputed state rather than attempting to “check a golden.”

### 4.6 Account per real lineage (P2 primary; P1 may defer)

Only on **unique** family events:

**P1:** May emit one accounting event per ledger-accepted normalized event using `last` / total policy locked by corpus study, without full multi-run lineage state — still **after** provenance. If intra-file interleaving remains ambiguous, apply containment fallback and set `accountingQuality = contained`.

P1 still requires an explicit reducer per canonical logical session (and therefore one per provisional sibling), never one family-global baseline:

```text
P1SessionAccountingState {
  countedTotals
  rawTotalsBaseline
  inheritedTotalsRemaining
  containmentTracker
}
```

Before unique child events are accounted, replay that session's copied-prefix occurrences through the state path with `billingDisposition = duplicate`: update/seed `rawTotalsBaseline`, consume inherited state where applicable, and leave `countedTotals` unchanged. Then process billable unique events. Intra-session interleaving may still latch that session's containment tracker and set `accountingQuality = contained`; it must not create or reuse a family-global watermark.

**P2:**

1. Use a stable task/agent/turn **lineage** id iff the fixture shows it identifies a cumulative sequence without collapsing independent requests.
2. Maintain a **separate cumulative baseline per lineage**.
3. If `last_token_usage` is proven per unique request, use it (optionally cross-checked against lineage-local total delta).
4. Use cumulative totals as validation and/or lineage-local fallback.
5. If lineage identity is genuinely ambiguous → **watermark + min-cap containment** as conservative fallback only (§0); set `accountingQuality = contained`.
6. Optional never-inflate ceiling may wrap the fallback path only.

#### 4.6.1 Billing suppression does not erase state

Provenance decides whether an event is billed; it does **not** decide whether the event is an observed cumulative-state transition:

- Ledger-accepted unique event: `billingDisposition = accepted`; it may seed/advance lineage state and emit its accounted delta.
- Copied ancestor event: `billingDisposition = duplicate`; it emits zero tokens/cost **but still seeds or advances the descendant's raw cumulative baseline**.
- At a resolved fork boundary, initialize each proven child lineage from the corresponding final parent cumulative snapshot at or before the fork.
- If lineage identity is not yet known, seed the P1/fallback reducer from the final filtered copied-prefix total (fork-inheritance adjusted), not zero.
- With a missing parent, use the provisional family's canonical pre-fork stream as state-only seed material for every sibling; ambiguous cases remain `accountingQuality = contained`.

Thus a parent ending at `100M`, followed by a child's first unique absolute total of `101M`, contributes `1M` — not `101M` — even though copied parent events were removed from billing.

Keep #1164 inherited total resolution as the baseline-seeding mechanism where applicable. Authoritative cross-file billing dedupe remains §4.5; state continuity remains mandatory after dedupe.

#### 4.6.2 Placement of #2066 containment

After family provenance lands, containment runs only inside one canonical session's **unique post-ledger stream**:

```text
family copies → provenance ledger → unique stream per canonical session
              → primary per-event/per-lineage accounting
              → session-local containment only if still ambiguous
```

Never apply one #2066 watermark across family members, and never let containment decide whether cross-file copies are duplicates. Provenance owns copy identity; containment is the final ambiguity guard for one already-deduplicated session stream.

### 4.7 Price only after reconciliation

Each unique event retains original model, pricing date, input, cached input, output, **and priority/turn metadata**. Price **individually** after deduplication so standard vs priority and other nonlinear tiers can be reproduced.

Both the pricing-catalog date and report-day bucket derive from the accepted event's **original timestamp**. Do not use scan time, cache-write time, fork time, parent restoration time, or the timestamp of a different copied occurrence.

Never subtract already-priced aggregates or price a collapsed lineage blob (#2043).

### 4.8 Change the cache boundary

Use a **two-tier derived cache** rather than embedding every normalized event in the existing monolithic JSON cache.

**Main manifest / family-result cache** (small, eagerly decoded):

- stable family ID (`rootSessionId` or provisional `missing:<parentSessionId>`)
- canonical logical-session members and all source path/file digests
- parser, normalized-event-schema, pricing, and reconciliation fingerprints
- accepted family contribution maps / cost nanos
- provenance/accounting quality fields and optional quality reasons
- references to member event sidecars

**Per-file or per-canonical-session event sidecars** (lazy, independently invalidatable):

- only normalized fields required for provenance, baseline continuity, and pricing
- no original JSON lines and no redundant final report aggregates
- versioned and atomically written
- loaded only for a dirty family or a forced rescan

“Lossless” here means lossless for the specified provenance/accounting inputs, not byte-for-byte preservation of source JSON. Source logs remain authoritative and every sidecar is disposable/rebuildable.

When one file changes:

1. Rebuild the same-session union if needed.
2. Reparse that file’s normalized events.
3. Determine its fork family.
4. Reconcile and reprice **that entire family**.
5. Replace the family’s previous contribution **atomically**, including its quality fields (§6).

**Initially avoid clever incremental family reconciliation.** Recompute the affected family.

When a source disappears, changes `sessionId`/parent, or moves between families, use the manifest to identify both the old and new affected families. Recompute both and update their contribution records in one in-memory cache transaction before the main cache is atomically saved. Write sidecars via temporary file + rename so an interrupted refresh cannot expose a half-written event set.

#### 4.8.1 Crash-safe generation protocol

1. Read one committed manifest generation `N`; readers ignore unreferenced sidecars.
2. Build all changed family results and sidecars for generation `N+1` in memory / temporary paths.
3. Atomically rename completed sidecars into content-addressed or generation-qualified final paths.
4. Write the complete `N+1` manifest (family membership, contributions, rolled-up day totals, quality, sidecar digests) to a temporary file and atomically rename it last. **The manifest rename is the commit point.**
5. On failure before the manifest commit, generation `N` remains authoritative; partial `N+1` sidecars are orphans and cannot affect totals.
6. Garbage-collect sidecars not referenced by the committed manifest after a successful commit or on a later startup/refresh.
7. Validate referenced sidecar schema + digest before use; a missing/corrupt sidecar invalidates only its affected family and triggers source reparse.

This prevents a crash during reparenting from mixing old family A contributions with new family B contributions. A monotonically increasing generation number plus sidecar content digests is sufficient; a separate complex checksum journal is not required.

**Day-total atomicity:** rolled-up day/model/cost maps are derived exclusively from the family contributions in the newly committed manifest generation. Never patch global day totals in place while ownership moves from family A to B. Generation `N` contains all old owners/totals; generation `N+1` contains all new owners/totals; no reader may observe a mixed generation containing both A's old and B's new contribution for one key.

Do not mandate run-length encoding, pruning, compression, or a particular binary format before measuring the sanitized corpus. First record:

- normalized sidecar bytes versus source-log bytes
- cold main-cache decode time
- dirty-family sidecar load + recompute time
- full rebuild time
- peak resident memory

Lock acceptable budgets before implementation freeze. If needed, optimize with string interning, columnar arrays, timestamp/ordinal deltas, or compression while preserving every normative field and golden result.

Bump `CodexParserHash`, the normalized-event sidecar schema, and clear compatible producer keys when this ships.

## 5. Identity contract (normative)

| Prefer | Avoid |
|--------|--------|
| Namespaced ID proven one-to-one with an accounting event and copied into children | Request/message ID assumed event-unique without cardinality proof |
| Exact pre-fork copied prefix under ancestor relationship | Token-value-only dedupe |
| Separate post-fork events even if counts match | Shared task id as sole key |
| Ambiguous → keep separate + degrade quality | Silent overwrite on ID collision |

## 6. Quality fields → report / UI

### 6.1 Provenance completeness ≠ accounting containment

These are **independent**. A family can be graph-incomplete **and** still use containment fallback — a single enum loses that information.

Persist **two fields** (or an equivalent set of quality reasons):

```text
enum CodexFamilyProvenanceQuality {
  case complete     // resolvable DAG, no conflicting parents / unhandled cycles
  case incomplete   // missing parent, cycle break, conflicting parents, etc.
}

enum CodexFamilyAccountingQuality {
  case primary      // corpus-proven per-event / per-lineage path (no containment)
  case contained    // watermark min-cap / containment fallback used
}
```

Persist a `Set<CodexFamilyQualityReason>` alongside the two fields. At minimum support and assert in goldens:

```text
missingParent
provisionalFamily
cycleBroken
conflictingParents
stableIdCollision
fingerprintCollision
ambiguousForkBoundary
containmentFallback
```

The UI may collapse reasons into simpler copy, but cache/CLI/test output must preserve them so `incomplete + contained` is diagnosable rather than a black box.

**Roll-up when aggregating days:** worst provenance and worst accounting independently (`complete` < `incomplete`; `primary` < `contained`).

### 6.2 Propagation path (implementation target)

1. **Scanner / family reconcile** assigns both quality fields per family.
2. **Cache** persists both fields and mandatory quality reasons with the family’s accepted events / cost nanos.
3. **`CostUsageDailyReport`** (and project breakdowns if present) expose rolled-up fields, e.g. `provenanceQuality` + `accountingQuality` (or derived `isEstimate` = either non-ideal).
4. **UI / menu:** distinct affordances when possible — e.g. “Incomplete fork history” vs “Estimated (conservative accounting)” — not a single vague “Estimated” that conflates the two.
5. **CLI** (`codexbar cost` JSON): include both fields and quality reasons so agents/scripts do not treat estimates as exact.

Exact UX copy TBD; the **data path for both dimensions** is required in P1 so quality is not documentation-only.

## 7. Canonical fingerprint (when IDs are absent)

Used only for the pre-fork exact-copy path or as a secondary assist — not global token dedupe.

**Copy-stable inputs only** (finalize from corpus), e.g.:

- event timestamp (if stable across copies)
- model
- raw `last_token_usage` when present
- raw `total_token_usage` snapshot when present
- any weak ids (`turn_id`, etc.) only as secondary components

**Do not include file-local ordinal** in the fingerprint unless the corpus proves ordinals survive copying. Surrounding insertions in a child log can shift ordinals even when the event is the same ancestor row. Ordinal remains useful as a **within-file or same-stream tie-break** after candidates are matched by copy-stable fields — not as identity.

**Fingerprint collision policy:**

- same high-confidence fingerprint + identical normalized accounting/provenance payload → copied duplicate candidate
- same high-confidence fingerprint + incompatible payload → keep events separate, record `fingerprintCollision`, set `provenanceQuality = incomplete`, and never merge or sum the payloads under one key
- low-confidence fingerprint → do not merge

## 8. Phased delivery

| Phase | Scope | Closes #2037? |
|-------|--------|----------------|
| **P0** | Spec; sanitized corpus; lock eventKey / exact-copy / identity contract | No |
| **P1** | Same-session union → cross-window family closure → normalize (+ priority metadata) → deterministic family/provisional graph → provenance ledger + ownership/baseline continuity → corpus-proven per-event accounting → per-event pricing → two-tier atomic family cache → quality fields/reasons through report/UI | **Only if** corpus proves the P1 per-event path **and** no affected golden family has `accountingQuality = contained`. `incomplete + primary` may close when its provisional-family oracle matches; otherwise ship non-closing and require P2 |
| **P2** | Per-lineage cumulative baselines; containment strictly fallback → clear remaining `contained` goldens | Required to close when P1 still needs containment on in-scope goldens |
| **P3** | Pi parity if logs match | Separate if needed |

[#2066](https://github.com/steipete/CodexBar/pull/2066) may merge earlier only as an **explicit non-closing** interim guard with owner approval and #2037 left open.

## 9. Test plan (after corpus locks keys)

**Corpus golden**

1. Family token total = hand oracle (no multi-file ancestor multi-charge).
2. Dollar total = hand oracle under nonlinear **and** standard vs priority splits.
3. Post-fork identical-but-distinct events preserved.
4. Quality fields and mandatory reasons match expected state (`provenanceQuality`, `accountingQuality` — including combinations such as incomplete + contained).
5. Two children copy the same pre-fork parent event → charged once.
6. **Two siblings reference the same unavailable parent** → provisional-family reason + `provenanceQuality = incomplete`; copied prefix bills once and family does not inflate (quality/ownership focus).
7. Same token vectors post-fork on siblings → not deduped.
8. Cycle in fork edges → deterministic break + `provenanceQuality = incomplete`.
9. Duplicate `sessionId` with conflicting parents → `provenanceQuality = incomplete`.
10. Stable-ID collision with incompatible payloads → no silent merge; `provenanceQuality = incomplete`.
11. Same-session active+archive → provenance-safe union stream before family graph; unique suffixes preserved exactly once.
12. Priority metadata preserved → standard vs priority totals match oracle.
13. Ambiguous lineage → containment fallback + `accountingQuality = contained`; no gap-billion inflation.
14. Touching one family member recomputes whole family; atomic replace ≡ full family rescan.
15. `#968` / `#1062` / `#1164` non-family regressions remain green.
16. Parent total `100M`, copied child prefix `100M`, first unique child total `101M` → copied row bills zero but seeds state; child bills exactly `1M`.
17. Delete a parent shared by two children → family cost never rises; warm-cache, cold-cache, and force-rescan results agree.
18. Missing-parent siblings with corpus-proven shared prefix → prefix represented once; both child baselines seeded; first unique absolute totals count only post-prefix growth (state-continuity focus); post-fork work remains distinct.
19. Enumerate the same cyclic edge set in every order and through incremental arrivals → identical accepted forest and quality reasons.
20. Parent outside the requested day window still seeds/dedupes an in-window child; filtering occurs after reconciliation.
21. Active partial + archived suffix for one `sessionId` → canonical logical stream preserves the union of unique events exactly once.
22. One request/message ID attached to multiple token snapshots → not collapsed unless a corpus-proven compound event sequence distinguishes copies.
23. Real parent present → parent owns copied key; remove parent → one sibling owns; restore parent → ownership migrates back, with the key billed once in every generation.
24. Parent restoration with additional unique parent events → known copied-key contribution does not rise; only newly discovered unique events add cost.
25. Every supported/ambiguous fork-boundary shape → selected corpus rule classifies prefix/post-fork rows exactly; ambiguous boundary records its reason and does not aggressively merge.
26. High-confidence fingerprint collision with incompatible payload → events remain separate and `fingerprintCollision` is asserted.
27. Quality-reason goldens assert at least `missingParent`, `provisionalFamily`, `cycleBroken`, `conflictingParents`, `stableIdCollision`, `fingerprintCollision`, `ambiguousForkBoundary`, and `containmentFallback` where applicable.
28. Crash before manifest commit → old generation remains authoritative; crash after commit → new family/day totals and sidecars are internally consistent; orphan GC does not alter totals.
29. Original event timestamp controls both pricing catalog date and report day across parent restoration, rescans, and copied occurrences.
30. Family ledger emits unique per-session streams before #2066 containment; no family-global watermark is created.
31. Same-session active/archive streams contain two legitimate identical occurrences → ordered union preserves multiplicity while suppressing only the copied overlap.
32. Grandparent and parent both contain key `K`; grandparent owns billing, while child baseline walks grandparent → parent → child and includes intervening unique parent growth.
33. Provisional family with proven shared keys/prefix → `incomplete + primary`; ambiguous representative path → `incomplete + contained`, with exact reasons asserted.
34. Session ownership moves family A → B → main manifest day totals contain exactly one generation's contribution, never A-old + B-new together.
35. Conflicting authoritative parent claims → no parent edge accepted and `conflictingParents`; non-authoritative inference alone never creates an edge.

**Performance / storage acceptance (sanitized corpus):** record the §4.8 metrics for cold cache, dirty-family refresh, and full rebuild; verify that loading one dirty family does not deserialize every event sidecar. Performance budgets must be agreed before implementation freeze, and optimized representations must remain golden-equivalent.

## 10. Fixture required first (design input)

A sanitized Ultra / multi-fork corpus must answer:

1. Which IDs survive when parent events are copied into child files, and what is each ID's cardinality (one event, one request with many snapshots, one lineage, etc.)?
2. Are copied lines byte-identical, or only field-equal after normalization?
3. Does `turn_id` identify a cumulative lineage, or only a turn span unsafe alone?
4. Is `last_token_usage` per-request, cumulative, or sometimes replayed?
5. What happens when a parent file is unavailable (including **two siblings → one missing parent**)?
6. How are priority turns represented so metadata can be normalized?
7. Do active/archive views with one `sessionId` contain unique suffixes that require unioning?
8. Are fork timestamps present, parseable, and physically consistent enough for timestamp-first graph ordering?
9. Which exact fork-boundary rule correctly separates copied prefix from child-local work, including ambiguous/missing metadata cases?
10. Does parent disappearance/reappearance preserve event keys and original timestamps well enough for deterministic ownership migration?

**Deliverables before implementation freeze:** hand token + dollar oracles; documented namespaced event-key cardinality / exact-copy rules; the exact locked fork-boundary rule text; duplicated ancestor chain; missing-parent siblings; baseline-continuity oracle; parent disappear/restore ownership-migration oracle; ambiguous-boundary goldens; redacted before/after output; expected quality fields/reasons per scenario; cache/performance measurements and agreed budgets.

## 11. Risks

| Risk | Mitigation |
|------|------------|
| No stable ID survives copies | Pre-fork exact-copy rule; else `accountingQuality = contained` / labeled estimate only |
| Request/message ID covers multiple token snapshots | Require event-level cardinality proof or a copy-stable compound sequence; otherwise use only as lineage hint |
| Over-dedupe | Identity contract; post-fork preserve; no token-only dedupe |
| Same-session unordered union collapses legitimate repeats | Ordered overlap alignment within one `sessionId`; preserve occurrence multiplicity and unmatched suffixes |
| Removing a parent increases cost | Provisional missing-parent family + file-removal monotonicity invariant + warm/cold regressions |
| Restoring a parent double-bills provisional keys | Per-key owner priority + atomic ownership migration; only new unique parent keys may add cost |
| Deduped prefix resets child cumulative baseline | Separate billing disposition from state disposition; copied observations seed state but bill zero |
| Earliest billable owner skips intervening parent state | Ownership controls billing only; baseline seeding walks the actual parent chain and every fork boundary |
| P1 “state-only” implemented as another global baseline | Explicit `P1SessionAccountingState` per canonical session/provisional sibling; no family-global watermark |
| Cycle result depends on file order | Timestamp-first accepted-forest algorithm over the whole component; stable ID tie-breaks |
| Wrong fork boundary over- or under-dedupes | Corpus-lock one boundary rule; ambiguous boundary records reason and uses conservative path |
| Out-of-window parent treated as missing | Build relevant family closure before report-date filtering |
| Same-session union drops an active/archive unique suffix | Union all same-session views before cross-session graph construction |
| Monolithic normalized-event JSON grows too large | Small manifest/family results + lazy disposable sidecars; benchmark before choosing compact encoding |
| Crash mixes old/new family ownership or day totals | Generation-qualified sidecars; manifest atomic rename as commit point; orphan GC |
| Family move patches day totals twice | Rebuild day maps solely from one committed generation's family contributions; never patch global totals in place |
| Copied occurrence changes price/report day | Preserve original event timestamp as both pricing-date and report-bucket source |
| Quality never reaches UI | §6 mandatory in P1 (both dimensions) |
| Single enum conflates provenance vs accounting | Dual fields / reason set (§6.1) |
| Same-session vs family ordering bugs | §3 hard order + test 11 |
| Conflicting authoritative parent claims delegated to cycle breaker | Accept no guessed edge; mark `conflictingParents`; run forest only after single-parent candidates are resolved |
| Treating #2066 as the fix | Fallback-only; leave #2037 open unless P1 close criteria met |
| Closing #2037 while goldens still use containment | Explicit P1 close gate (§0, §8); otherwise P2 required |

## 12. Open questions for steipete / reporter

1. First milestone corpus: Codex JSONL, Pi, or both?
2. Acceptable dollar tolerance vs hand oracle?
3. Interim non-closing merge of [#2066](https://github.com/steipete/CodexBar/pull/2066) while P0–P1 proceed?
4. Preferred UI strings for `provenanceQuality = incomplete` vs `accountingQuality = contained` (including when both apply)?
5. Confirm the close gate: an oracle-matching `incomplete + primary` provisional family is acceptable, but any affected golden with `accountingQuality = contained` keeps #2037 open for P2?

## 13. Summary

Strong basis for implementation once the fixture locks keys:

- **Fixture-first** gate
- **Ordered same-session union** that preserves multiplicity and unique suffixes
- **Cross-window family closure** before date filtering
- **Provenance separated from accounting**
- **One billable owner per event key**, with atomic ownership migration when a parent disappears/reappears
- **Billing ownership separate from parent-chain baseline propagation**
- **Billing suppression preserves baseline state** for copied prefixes
- **Explicit P1 session reducer**, never a family-global baseline
- **Provisional missing-parent families** with file-removal monotonicity
- **Explicit provisional `primary` vs `contained` fork** based on corpus-proven identity
- **Corpus-locked fork-boundary rule** with an explicit ambiguous path
- **Refuse token-only deduplication**
- **Event-level ID cardinality**, not merely ID copy survival
- **Price after reconciliation** (with priority metadata preserved)
- **Containment only as fallback**
- **Correct P1/P2 boundary and close gate** — P1 closes #2037 only with proven per-event path and no contained goldens; otherwise P2 required
- **Identity contract** with copy-stable fingerprints (ordinal tie-break only unless corpus proves otherwise)
- **Explicit pipeline order** (same-session union before families)
- **Timestamp-first deterministic cycle handling**
- **Two-tier derived cache** with lazy sidecars and measured performance budgets
- **Manifest-generation commit protocol** with crash isolation and orphan sidecar GC
- **Day totals derived from one committed family generation**, never patched across moves
- **Dual quality fields** (provenance × accounting) with a real report/UI path
- **Mandatory quality reasons** asserted by goldens and exposed through cache/CLI
- **Event-local pricing/report dates** across rescans and ownership migration
- **Invalid graph / ID collision** states defined
- **Sibling missing-parent** coverage in tests

File-local containment alone cannot close #2037. This scan-wide provenance design can — after the corpus locks the keying rules, and only when the close criteria in §0 / §8 are met.

**Stop condition for prose:** after rev 8, do not begin P1 or add speculative key schemes until P0 locks §10.1 (event-key cardinality), §10.9 (fork-boundary rule), and §10.10 (ownership migration through parent disappearance/reappearance).

**Local P0 progress (2026-07-11, rev 2):** `docs/issue-2037-p0-local-corpus-findings.md` locks §10.1 / §10.9 for ordinary Codex rollout forks and records scanner-integration results:

- No per-`token_count` event ID; ordered normalized `(last,total)` contiguous prefix under ancestry; timestamps rewritten on copy (exclude from fingerprint); leaf `session_meta` is authoritative.
- Sanitized fixture `archived-fork-33ce-3869` + oracle tests are in-repo.
- **Parent present:** `#1164` inherited totals already match the parent-owns-prefix scanner-unit oracle (`Issue2037ScannerIntegrationTests`) — regression-locked, not a new ledger.
- Local Ultra/Sol–Terra parallel runs did **not** produce interleaved `total_token_usage` drops; do not block cross-file work on drops.
- **Still open for close criteria:** Ultra interleaved corpus, fuller event-key ledger / ownership migration, priority/`logs_2` join.
- **Missing-parent siblings:** sanitized fixture + hand oracle landed. Runtime token-only prefix suppression was removed because equal-counter distinct events are ambiguous; the scanner fails open until the P1 identity/quality path exists.
