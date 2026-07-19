---
summary: "Locked implementation plan for Claude provider vNext: resolved source-selection contracts, typed credential rules, siloing guarantees, and phase gates."
supersedes: "Initial vNext draft (removed)"
created: "2026-02-18"
status: "Locked for implementation"
---

# Claude provider vNext (locked plan)

This is the implementation-locked vNext plan.

It preserves the original architecture direction, but removes ambiguity in behavior-critical areas before refactor work starts.

Current-state parity reference for present behavior:

- [docs/refactor/claude-current-baseline.md](claude-current-baseline.md)

Use the baseline doc for present behavior. This vNext plan defines what the refactor should preserve and how it should
be staged; it is not the sole source of truth for current implementation details, and RAT-107 does not re-approve the
rest of the future architecture below.

## Assessment snapshot

- **Approach score:** `8.4/10`.
- **Why not 9+ yet:** the original plan left runtime ordering, token-account credential typing behavior, and compatibility mapping under-specified.
- **How this doc closes the gap:** explicit contracts + resolved decisions + phase exit gates + risk checklist.
- **Validated gap coverage in this version:** explicit `.auto` inconsistency handling, `ClaudeUsageFetcher` decomposition, stronger parity gates, TaskLocal-to-DI migration, and OAuth decomposition sub-phases.

## Locked behavioral contracts

These behaviors are **non-negotiable** during refactor unless this doc is explicitly updated.

### 1) Runtime + source-mode contract

`ClaudeSourcePlanner` must reproduce this matrix exactly:

| Runtime | Selected mode | Ordered attempts | Fallback rules |
| --- | --- | --- | --- |
| app | auto | oauth -> cli -> web | oauth fallback allowed; cli fallback to web only when web available; web terminal |
| app | oauth | oauth | no fallback |
| app | cli | cli | no fallback |
| app | web | web | no fallback |
| cli | auto | web -> cli | web fallback allowed to cli; cli terminal |
| cli | oauth | oauth | no fallback |
| cli | cli | cli | no fallback |
| cli | web | web | no fallback |

Notes:
- `sourceLabel` remains the final step label for successful fetch output.
- Planner diagnostics must include ordered steps and inclusion reasons.
- Planner output must feed the existing generic provider fetch pipeline; do not introduce a second Claude-only
  execution stack alongside `ProviderFetchPlan` / `ProviderFetchPipeline`.

### 1a) `.auto` inconsistency characterization contract (must-do before reconciliation)

Current code has three `.auto` decision sites with inconsistent app ordering:

- Strategy pipeline resolve order (app): `oauth -> cli -> web`.
- `resolveUsageStrategy` helper order: `oauth -> cli -> web -> cli fallback`.
- `ClaudeUsageFetcher.loadLatestUsage(.auto)` order: `oauth -> web -> cli -> oauth fallback`.

Phase 0 must characterize these paths with tests where they are reachable through stable seams, and otherwise defer to
the baseline doc before deleting any path.
Phase 2 must reconcile this into planner-only source selection.

### 2) Prompt/cooldown contract

The planner must use one explicit `ClaudePromptDecision` equivalent, but outcome parity with current behavior is required:

- User-initiated actions can clear prior keychain cooldown denial.
- Startup bootstrap prompt is only allowed when all are true:
  - runtime is app
  - interaction is background
  - refresh phase is startup
  - prompt mode is `onlyOnUserAction`
  - no cached credentials
- Background delegated refresh is blocked when:
  - prompt policy is `onlyOnUserAction`
  - caller does not explicitly allow background delegated refresh
- Prompt mode `never` blocks delegated refresh attempts.

### 3) Credential typing + routing contract

Typed credentials must be introduced at the settings snapshot edge, with behavior parity:

- `ClaudeManualCredential.sessionKey`
- `ClaudeManualCredential.cookieHeader`
- `ClaudeManualCredential.oauthAccessToken`

Accepted Claude token-account inputs must continue to work:

- Raw OAuth token (including `Bearer ...` input)
- Raw session key
- Full cookie header

Routing parity requirements:

- OAuth token account values must route to OAuth path (not cookie mode).
- Cookie/session-key account values must route to web cookie path.
- CLI token-account behavior must remain consistent in both app and `CodexBarCLI`.
- Scope note: current string heuristics are mostly edge-routing logic, not deep OAuth credential decoding internals.

### 4) Ownership and refresh contract

Credential owner behavior must remain identical:

- `.claudeCLI` expired credentials: delegated refresh path.
- `.codexbar` expired credentials: direct refresh endpoint path.
- `.environment` expired credentials: no auto-refresh.

Refresh failure-gate semantics must remain unchanged.

### 5) Provider siloing + enrichment contract

Hard invariant:

- Never merge Claude Web identity into OAuth/CLI snapshots.
- Web extras may enrich **cost only**.
- Snapshot identity must always remain provider-scoped to `.claude` when persisted/displayed.

### 6) Plan inference compatibility contract

Canonical plan inference can live behind the existing `loginMethod` compatibility surface, but outward
compatibility must be preserved:

- Existing detectable plans continue mapping to display strings:
  - `Claude Max`
  - `Claude Pro`
  - `Claude Team`
  - `Claude Enterprise`
- Subscription detection behavior must remain compatible with current UI logic, including existing `Ultra` detection
  semantics until that behavior is explicitly changed.

### 7) Documentation + diagnostics contract

- During refactor, characterization coverage plus
  [docs/refactor/claude-current-baseline.md](claude-current-baseline.md)
  are the source of truth when docs and code disagree.
- `docs/claude.md` must be updated as part of Phase 0 after characterization lands so it no longer presents divergent
  runtime ordering as settled behavior.
- Debug surfaces must consume planner-derived diagnostics instead of recomputing Claude source decisions separately.

## Resolved decisions (from open questions)

### Web identity fill-ins

- **Decision:** do not use Web identity to fill missing OAuth/CLI identity fields.
- **Allowed:** Web cost enrichment only.

### CLI runtime fallback ordering

- **Decision:** keep current CLI ordering in `auto`: `web -> cli`.
- Planner must encode this explicitly and not rely on incidental strategy ordering.

### Startup bootstrap prompt in `onlyOnUserAction`

- **Decision:** keep support exactly under the startup bootstrap constraints listed above.
- Any expansion/restriction requires explicit doc update and tests.

### Runtime policy unification timing

- **Decision:** do not unify app and CLI `auto` ordering before this refactor.
- First consolidate to one planner implementation with current runtime-specific behavior preserved.
- Any runtime-policy unification is a separate, explicit behavior-change follow-up.

### Planner integration timing

- **Decision:** `ClaudeSourcePlanner` must be integrated into the existing provider descriptor / fetch pipeline rather
  than added as a parallel orchestration layer.
- Reuse current `ProviderFetchContext` / `ProviderFetchPlan` plumbing where possible.

### Dependency seam timing

- **Decision:** introduce dependency-container seams for newly extracted planner/executor components as they are
  created.
- Full TaskLocal cleanup can remain later, but new components should not deepen TaskLocal coupling.

## Locked migration plan with exit gates

### Phase 0: Baseline lock

Deliverables:
- Add `docs/refactor/claude-current-baseline.md` as the current-state behavior reference.
- Add/refresh characterization tests for runtime/source matrix and prompt-decision parity.
- Add explicit characterization tests for existing `.auto` decision paths where they are reachable through stable seams,
  and defer remaining current-state details to the baseline doc until later reconciliation.
- Update `docs/claude.md` after tests land so documented ordering matches characterized behavior.

Exit gate:
- Behavior matrix tests pass for app and cli runtimes.
- `.auto` characterization coverage plus the baseline doc record current divergence explicitly without forcing new
  production seams in Phase 0.
- `docs/claude.md` no longer contradicts characterized runtime/source behavior.

### Phase 1: Canonical plan resolver

Deliverables:
- Introduce `ClaudePlan` + one resolver used by OAuth/Web/CLI mapping and downstream UI consumers.

Exit gate:
- Plan mapping tests cover tier/billing/status-derived hints, compatibility display strings, and current UI subscription
  detection compatibility.

### Phase 1b: Typed credentials at the snapshot edge

Deliverables:
- Parse manual Claude credentials once at the app + CLI snapshot edges into a typed model.
- Remove duplicated edge-routing heuristics for OAuth-vs-cookie decisions across settings snapshots and token-account
  CLI code.

Exit gate:
- Token account parity tests pass for app + CLI.
- Snapshot-edge routing no longer duplicates Claude OAuth-token detection logic in multiple call sites.

### Phase 2: Single source planner

Deliverables:
- Introduce `ClaudeSourcePlanner` + explicit `ClaudeFetchPlan`.
- Integrate planner outputs into the existing provider pipeline / descriptor flow.
- Remove duplicate `.auto` policy branches from lower layers.
- Reconcile and remove `ClaudeUsageFetcher` internal `.auto` source selection.
- Move debug/diagnostic surfaces to planner-derived attempt ordering instead of helper-specific recomputation.

Exit gate:
- One authoritative planner path for mode/runtime ordering.
- Fallback attempt logs still show expected sequence and source labels.
- No surviving `.auto` source-order logic outside planner.
- No surviving debug-only source-order recomputation outside planner diagnostics.
- Old-vs-new planner parity tests pass before old branches are removed.

### Phase 2b: `ClaudeUsageFetcher` decomposition

Deliverables:
- Split `ClaudeUsageFetcher` into smaller executor-focused components.
- Extract delegated OAuth retry/recovery flow into dedicated units.
- Remove embedded prompt-policy/source-selection ownership from fetcher; keep it execution-only.

Exit gate:
- Fetcher no longer owns source-selection policy.
- Delegated OAuth retry behavior is covered by dedicated tests and remains parity-compatible.

### Phase 3: Test injection cleanup

Deliverables:
- Prefer dependency seams on extracted units instead of adding new TaskLocal-only override points.
 - Avoid expanding TaskLocal-only test hooks while decomposition work lands.

Exit gate:
- New fetcher tests rely on explicit dependency seams where practical.

### Phase 4: OAuth decomposition

Deliverables (sub-phases):

- **Phase 4a (repository extraction):**
  - Extract IO + caching + owner/source loading into repository surface.
  - Keep prompt-gate semantics unchanged.
- **Phase 4b (refresher extraction):**
  - Extract network refresh + failure gating to refresher component.
  - Keep owner-based refresh behavior unchanged.
- **Phase 4c (delegated controller extraction):**
  - Extract delegated CLI touch + keychain-change observation + cooldown behavior.
  - Keep delegated retry outcomes unchanged.

Exit gate:
- Existing OAuth delegated refresh / prompt policy / cooldown suites pass without behavior deltas at each sub-phase.
- Owner semantics parity remains intact across all sub-phases (`claudeCLI`, `codexbar`, `environment`).

### Phase 5: Test injection migration (TaskLocal -> DI)

Deliverables:
- Move test injection from TaskLocal-heavy overrides to `ClaudeFetchDependencies` and explicit protocol stubs.
- Keep compatibility shims temporarily where needed, then remove them.

Exit gate:
- Core planner/executor tests run without TaskLocal injection dependencies.
- Legacy TaskLocal-only override surfaces are either removed or isolated to compatibility adapters with deletion TODOs.

### Phase 6: Web decomposition (optional)

Deliverables:
- Separate cookie acquisition from web usage client.
- Keep probe tooling isolated behind debug/tool surface.

Exit gate:
- Web parsing and account mapping tests remain green.

## Implementation PR plan (stacked)

Use this sequence to keep each PR reviewable without turning the rollout into unnecessary PR overhead.

| PR | Title | Scope | Primary risks | Must-pass gate before merge |
| --- | --- | --- | --- | --- |
| PR-01 | Baseline characterization + doc correction | Lock current matrix behavior, characterize `.auto` paths through stable seams, defer remaining lower-level current-state details to the baseline doc, characterize prompt bootstrap/cooldown and token-account routing, then update docs to match reality. | R1, R2, R5, R6, R10 | No production behavior changes; characterization suites green; docs no longer contradict tests or the baseline. |
| PR-02 | Canonical plan resolver | Introduce `ClaudePlan` and central resolver; map OAuth/Web/CLI/UI compatibility through one model while preserving current `loginMethod` projections. | R8 | Plan compatibility tests green (`Max/Pro/Team/Enterprise` + current subscription compatibility). |
| PR-03 | Typed credentials at the edge | Parse manual credentials once (`sessionKey`, `cookieHeader`, `oauthAccessToken`) in app + CLI snapshot shaping. | R6 | Token-account routing parity tests green in app + CLI contexts. |
| PR-04 | Source planner introduction + cutover | Add `ClaudeSourcePlanner`, prove parity against old path, then remove duplicate `.auto` selection branches once parity is proven. | R1, R5, R10 | One `.auto` authority remains; attempt/source-label diagnostics remain parity-compatible. |
| PR-05 | `ClaudeUsageFetcher` decomposition | Split fetcher into execution/retry-focused units; remove embedded source-selection ownership. | R2, R10 | Delegated OAuth retry/recovery tests green with no behavior deltas. |
| PR-06 | OAuth decomposition | Extract repository, refresher, and delegated-controller seams from `ClaudeOAuthCredentialsStore` while preserving owner semantics. | R3, R4, R7, R9 | Cache/fingerprint/prompt/owner suites green (`claudeCLI`, `codexbar`, `environment`). |
| PR-07 (optional) | TaskLocal -> DI migration | Move remaining tests and seams to `ClaudeFetchDependencies`, keep temporary compat adapters, then remove. | R9 | Core planner/executor tests run without TaskLocal globals. |
| PR-08 (optional) | Web decomposition | Split cookie acquisition from web usage client and keep tooling isolated. | R8, R10 | Web parsing/account mapping suites remain green. |

Stacking rules:

1. Keep each PR scoped to one risk cluster and one merge gate.
2. Do not remove old branches until a prior PR has old-vs-new parity tests in CI.
3. If a PR intentionally changes behavior, update this locked doc in the same PR and call it out in summary.
4. Prefer 6 core PRs unless parity risk forces a temporary split; do not fragment the rollout further without a
   concrete rollback or reviewability reason.

## Mandatory test additions

Add these test groups before or during Phases 1-3, then extend for later phases:

1. Planner matrix tests:
   - `(runtime x selected mode x interaction x refresh phase x availability)` -> exact step order + fallback.
2. `.auto` divergence characterization tests:
   - Lock current behavior of strategy pipeline vs `resolveUsageStrategy` helper vs fetcher-direct `.auto`.
   - Use as guardrails while consolidating to planner-only logic.
3. Typed credential parsing tests:
   - OAuth token, bearer token, session key, cookie header, malformed strings.
4. Cross-provider identity isolation tests:
   - Ensure `.claude` identity does not leak via snapshot scoping/merging.
5. Source-label and attempt diagnostics tests:
   - Validate final source label and attempt list parity.
6. CLI token-account parity tests:
   - `TokenAccountCLIContext` and app settings snapshot behavior match for OAuth-vs-cookie routing.
7. Old-vs-new parity tests:
   - Compare old path and planner path outputs before branch removals in Phase 2 and Phase 2b.
8. DI migration tests:
   - Ensure new dependency container can drive planner/executor tests without TaskLocal globals.

## Risk checklist (implementation review)

Use these risk IDs in refactor PR checklists/reviews.

| Risk ID | Severity | Risk | Detail |
| --- | --- | --- | --- |
| R1 | Critical | Auto-ordering reconciliation | Three `.auto` paths are inconsistent today. Characterize strategy pipeline vs `resolveUsageStrategy` helper vs fetcher-direct `.auto` before deleting any path. |
| R2 | High | Prompt policy consolidation | Prompt policy exists across strategy availability, fetcher flow, and credentials store gates. Preserve startup bootstrap constraints exactly to avoid prompt storms or silent OAuth suppression. |
| R3 | High | `ClaudeOAuthCredentialsStore` decomposition | Large lock-protected state + layered caches + fingerprint invalidation + security calls. Splits can break cache coherence, invalidation timing, or prompt gating order. |
| R4 | High | Owner semantics drift | Preserve exact owner-to-refresh mapping: `.claudeCLI` delegated, `.codexbar` direct refresh, `.environment` no refresh. |
| R5 | Medium | CLI runtime parity | Preserve runtime-specific policy: CLI `auto` remains `web -> cli`; OAuth is available only when explicitly selected as `sourceMode=.oauth`. Do not accidentally default CLI runtime to app ordering. |
| R6 | Medium | Token-account OAuth-vs-cookie misrouting | Keep routing parity for OAuth token vs session key vs full cookie header, including `Bearer sk-ant-oat...` normalization. |
| R7 | Medium | Cache invalidation regressions | Preserve credentials file/keychain fingerprint semantics and stale-cache guards during repository extraction. |
| R8 | Low-Medium | Plan inference heuristic drift | Preserve web-specific plan inference fallback (`billing_type` + `rate_limit_tier`) when unifying plan resolution. |
| R9 | Medium | Strict concurrency / `@Sendable` regressions | Maintain thread-safe behavior from current NSLock-based state while moving to DI/decomposed components under Swift 6 strict concurrency. |
| R10 | Low | Debug/diagnostic drift | Keep source labels, attempt sequences, and debug output aligned with real planner decisions after consolidation. |

## Change-control rule

Any refactor PR that intentionally changes one of the locked contracts above must:

1. Update this document.
2. Add/adjust tests proving the new behavior.
3. Call out the behavior change explicitly in the PR summary.
