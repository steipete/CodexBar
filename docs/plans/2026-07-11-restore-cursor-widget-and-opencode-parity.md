# Cursor Widget, Cost Diagnostics, and OpenCode Workspace Parity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restore the selected custom Cursor widget/cost/detail behavior and OpenCode workspace-account flow on the upstream-replay branch, without bringing back Codex legacy accounts, the dependent-process panel, z.ai changes, or utilization charts.

**Architecture:** Keep the replay branch's current Cursor probe, all-or-nothing event-completeness contract, and upstream app/menu infrastructure. Port only the custom presentation/data seams: richer `WidgetSnapshot` cursor summaries, conservative model-cost estimates, expanded request diagnostics, and OpenCode's explicit workspace-account model. Persist presentation-ready values in the snapshot, but derive selected Cursor ranges from existing settings and OpenCode workspace identity from existing token accounts.

**Tech Stack:** Swift 6, SwiftPM, Swift Testing, SwiftUI, AppKit menu hosting, WidgetKit/App Intents, existing `CostUsagePricing`, `CursorStatusProbe`, `SettingsStore`, and `OpenCodeUsageFetcher`.

---

## Scope and guardrails

Included:

- Cursor widget: selected-range total, approximate-total text, request date range, and per-request cost labels.
- Cursor model costs: `extra-high` normalization, complete/partial/total-only pricing behavior, and truthful exact-versus-approximate text.
- Cursor request details: weighted request-cost display and expanded diagnostic details while retaining scroll behavior.
- OpenCode: saved workspace identities, discovery/import, provider settings, menu switching, and widget switching.

Explicitly excluded:

- Codex legacy `auth.json` multi-account compatibility and dependent-process diagnostics.
- Provider utilization charts/median line, z.ai limit details, icon changes, and unrelated fork backports.
- Any new network dependency or a Cursor network request when the user switches `Cycle` / `30d`.

The implementation must retain the existing upstream Cursor enterprise usage parsing and all-or-nothing diagnostic behavior. Never show an incomplete event set as a complete cost total.

### Task 1: Establish the replay-branch baseline and capture regression contracts

**Files:**

- Inspect: `Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe.swift`
- Inspect: `Sources/CodexBar/UsageStore+WidgetSnapshot.swift`
- Inspect: `Sources/CodexBarCore/WidgetSnapshot.swift`
- Inspect: `Sources/CodexBar/Providers/OpenCode/OpenCodeProviderImplementation.swift`
- Test: `Tests/CodexBarTests/CursorRequestCostReplayTests.swift`
- Test: `Tests/CodexBarTests/CursorStatusProbeTests.swift`
- Test: `Tests/CodexBarTests/WidgetSnapshotTests.swift`
- Test: `Tests/CodexBarTests/OpenCodeUsageParserTests.swift`

**Step 1: Confirm branch and worktree isolation**

Run:

```bash
git status --short --branch
git worktree list --porcelain
```

Expected: work is performed only in `/Users/valsaraj/.codex/worktrees/cursor-upstream-replay`; do not stage or edit the dirty custom workspace.

**Step 2: Run the focused baseline**

Run:

```bash
swift test --filter CursorRequestCostReplayTests --filter CursorStatusProbeTests --filter WidgetSnapshotTests --filter OpenCodeUsageParserTests
```

Expected: current tests pass before changes. If the known post-test snapshot-write hang recurs after all test cases report success, record it separately; do not treat it as a test assertion failure.

**Step 3: Add characterization tests for the missing presentation contract**

Add focused tests that prove the current behavior is insufficient:

```swift
@Test
func `cursor widget preserves approximate selected range total and calendar range`() {
    let summary = CursorRangeUsageSummary(/* priced exact + lower-bound rows */)
    let entry = UsageStore.makeWidgetEntry(/* Cursor snapshot selecting .billingCycle */)

    #expect(entry.tokenUsage?.sessionCostText == "Approx. $…+")
    #expect(entry.tokenUsage?.sessionLabel == "Cycle")
    #expect(entry.cursorRequestRange?.start == summary.range.start)
    #expect(entry.cursorRequestRange?.end == summary.range.end)
}
```

Add tests for a weighted `requestsCosts: 2` row and for a widget snapshot missing the new fields so schema decoding remains backward-compatible.

**Step 4: Run the new tests RED**

Run:

```bash
swift test --filter CursorWidgetSnapshotTests --filter WidgetSnapshotTests --filter MenuCardCursorRequestDetailsTests
```

Expected: failures identify missing approximate-total text, calendar range rendering, and weighted request detail behavior.

**Step 5: Commit the test-only baseline**

```bash
git add Tests/CodexBarTests/CursorWidgetSnapshotTests.swift Tests/CodexBarTests/WidgetSnapshotTests.swift Tests/CodexBarTests/MenuCardCursorRequestDetailsTests.swift
git commit -m "test(cursor): characterize custom diagnostic parity"
```

### Task 2: Restore Cursor model normalization and honest cost estimates

**Files:**

- Modify: `Sources/CodexBarCore/Providers/Cursor/CursorModelNormalizer.swift`
- Modify: `Sources/CodexBarCore/Providers/Cursor/CursorRequestCostEstimator.swift`
- Modify: `Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift` only for an actually missing verified model rate
- Modify: `Sources/CodexBarCore/UsageFormatter.swift`
- Test: `Tests/CodexBarTests/CursorRequestCostReplayTests.swift`
- Create: `Tests/CodexBarTests/CursorRequestCostEstimatorTests.swift`
- Test: `Tests/CodexBarTests/CostUsagePricingTests.swift`
- Update: `docs/cursor.md`

**Step 1: Write model and estimate tests first**

Cover these inputs without adding unverified prices:

```swift
@Test
func `gpt extra high effort keeps the priced base key`() {
    let model = CursorModelNormalizer.normalize("gpt-5.5-extra-high")
    #expect(model.pricingKey == "gpt-5.5")
    #expect(model.effort == "extra-high")
}

@Test
func `total only priced GPT produces a conservative lower bound`() {
    let estimate = CursorRequestCostEstimator.estimate(for: .init(/* gpt-5.5, total tokens only */))
    #expect(estimate.confidence == .approximateLowerBound)
    #expect(UsageFormatter.cursorEstimateText(estimate)?.hasPrefix("Approx.") == true)
}
```

Add exact OpenAI, Anthropic, and Composer fixtures that prove cache fields are counted according to the documented pricing contract. Add partial and missing-breakdown cases that must remain visibly approximate or unavailable rather than fabricated exact values.

**Step 2: Run pricing tests RED**

Run:

```bash
swift test --filter CursorRequestCostReplayTests --filter CursorRequestCostEstimatorTests --filter CostUsagePricingTests
```

Expected: `extra-high` and the custom fallback/summary cases fail before the implementation is restored.

**Step 3: Restore the minimal normalizer and estimator behavior**

- Treat `extra-high` as one effort suffix, never as part of the price key.
- Reuse `CostUsagePricing` for all OpenAI/Anthropic rates; verify every added rate against its official provider source and record the date in `docs/cursor.md`.
- Price exact rows only when the published rate and required token components are known.
- For total-only/partial rows, preserve the custom conservative range or lower-bound behavior and use `Approx.` / `Partial`, never `Est.`.
- Keep Composer cache-token treatment and its caveat explicit.
- Summaries must aggregate exact values only when all priced contributions are exact; otherwise persist an approximate range or one-sided lower bound.

**Step 4: Make formatters render every honest result**

Implement/restore the aggregate formatter contract:

```swift
UsageFormatter.cursorEstimatedTotalText(summary)
// exact:       "Est. $12.34"
// bounded:     "Approx. $4.10-$18.70"
// lower-bound: "Approx. $4.10+"
```

Unknown/unpriced rows remain `nil`; they must not suppress valid contributions from other rows.

**Step 5: Run pricing tests GREEN and commit**

Run:

```bash
swift test --filter CursorModelNormalizerTests --filter CursorRequestCostReplayTests --filter CursorRequestCostEstimatorTests --filter CostUsagePricingTests
```

Then commit:

```bash
git add Sources/CodexBarCore/Providers/Cursor/CursorModelNormalizer.swift Sources/CodexBarCore/Providers/Cursor/CursorRequestCostEstimator.swift Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift Sources/CodexBarCore/UsageFormatter.swift Tests/CodexBarTests/CursorModelNormalizerTests.swift Tests/CodexBarTests/CursorRequestCostReplayTests.swift Tests/CodexBarTests/CursorRequestCostEstimatorTests.swift Tests/CodexBarTests/CostUsagePricingTests.swift docs/cursor.md
git commit -m "fix(cursor): restore honest model cost estimates"
```

### Task 3: Restore the Cursor widget summary, cycle period, and row costs

**Files:**

- Modify: `Sources/CodexBar/UsageStore+WidgetSnapshot.swift`
- Modify: `Sources/CodexBarCore/WidgetSnapshot.swift`
- Modify: `Sources/CodexBarWidget/CodexBarWidgetViews.swift`
- Test: `Tests/CodexBarTests/CursorWidgetSnapshotTests.swift`
- Test: `Tests/CodexBarTests/CodexBarWidgetProviderTests.swift`
- Test: `Tests/CodexBarTests/WidgetSnapshotTests.swift`
- Update: `docs/widgets.md`

**Step 1: Add failing snapshot tests for the selected Cursor range**

Assert that a selected `Cycle` and a selected `30d` range each persist:

- `sessionLabel` (`Cycle` or `30d`),
- exact cost or approximate cost text,
- total tokens,
- the selected range start/end,
- request rows with compact model label, weighted request-cost label, and estimate text.

Also decode a pre-change fixture to ensure optional additions do not drop old provider entries.

**Step 2: Run widget tests RED**

Run:

```bash
swift test --filter CursorWidgetSnapshotTests --filter CodexBarWidgetProviderTests --filter WidgetSnapshotTests
```

Expected: selected-range labels, approximate totals, or calendar-period assertions fail.

**Step 3: Extend `WidgetSnapshot` compatibly**

Add optional fields only:

```swift
public let sessionCostText: String?
public let sessionLabel: String?
public let last30DaysLabel: String?
```

Keep existing numeric cost/token fields and `CursorRequestRange` decoding intact. Do not alter old snapshot defaults or change the app-group storage key.

**Step 4: Build the Cursor-specific snapshot path**

In `UsageStore+WidgetSnapshot.swift`:

- select the already fetched `CursorRangeUsageSummary` matching `settings.cursorUsageRangeKind`;
- use `cursorEstimatedTotalText` when the aggregate is approximate;
- keep a numeric cost only for exact aggregates;
- persist the actual range start/end, falling back only when diagnostics are known complete;
- retain at most 30 rows, sort newest-first, and preserve model/request/estimate fields.

The widget must not derive a fake total from a capped request list.

**Step 5: Render summary and period in every relevant widget family**

In `CodexBarWidgetViews.swift`:

- label the summary with the selected range (`Cycle` / `30d`), not `Today`;
- render `sessionCostText` before numeric cost;
- render `MMM d – MMM d` from `CursorRequestRange` above details, including when the range has no visible request row;
- keep compact widget layouts readable and preserve the existing no-hover constraint.

**Step 6: Run widget tests GREEN and commit**

Run:

```bash
swift test --filter CursorWidgetSnapshotTests --filter CodexBarWidgetProviderTests --filter WidgetSnapshotTests
```

Then commit:

```bash
git add Sources/CodexBar/UsageStore+WidgetSnapshot.swift Sources/CodexBarCore/WidgetSnapshot.swift Sources/CodexBarWidget/CodexBarWidgetViews.swift Tests/CodexBarTests/CursorWidgetSnapshotTests.swift Tests/CodexBarTests/CodexBarWidgetProviderTests.swift Tests/CodexBarTests/WidgetSnapshotTests.swift docs/widgets.md
git commit -m "feat(cursor): restore widget cycle diagnostics"
```

### Task 4: Restore expanded Cursor request diagnostics in the menu

**Files:**

- Create: `Sources/CodexBar/MenuCardTokenDetailsView.swift`
- Modify: `Sources/CodexBar/MenuCardCursorTokenUsage.swift`
- Modify: `Sources/CodexBar/MenuCardView.swift`
- Modify: `Sources/CodexBarCore/UsageFormatter.swift`
- Modify: `Sources/CodexBar/StatusItemController+MenuCardInteractionPolicy.swift` only if a new detail surface needs explicit wheel forwarding
- Test: `Tests/CodexBarTests/MenuCardCursorRequestDetailsTests.swift`
- Test: `Tests/CodexBarTests/MenuCardInteractionPolicyTests.swift`
- Test: `Tests/CodexBarTests/MenuCardModelTests.swift`
- Update: `docs/cursor.md`

**Step 1: Write the diagnostic-row model tests**

Cover a request row with a weighted `requestCost` and token breakdown. Assert the expanded text contains:

```swift
#expect(lines.contains("Request cost: 2"))
#expect(lines.contains(where: { $0.hasPrefix("Model: ") }))
#expect(lines.contains(where: { $0.contains("cache read") }))
#expect(lines.contains(where: { $0.hasPrefix("Approx.") || $0.hasPrefix("Est.") }))
```

Also assert the compact row keeps the semantic count `Req 1`; weighted cost belongs only in its explicit diagnostic line.

**Step 2: Run menu-model tests RED**

Run:

```bash
swift test --filter MenuCardCursorRequestDetailsTests --filter MenuCardModelTests --filter MenuCardInteractionPolicyTests
```

Expected: the tests fail until the custom detail model and interaction policy are present.

**Step 3: Restore the detail formatter and view**

- Add a compact, typed detail view opened from the request row; do not port the unrelated copy overlay.
- Reuse one formatter for raw model, exact timestamp, semantic request count, weighted cost, token breakdown, estimate, source/caveat, and legacy request-based disclaimer.
- Keep the detail data local to Cursor. Do not expose Claude/Codex identity or plan metadata in the Cursor view.

**Step 4: Preserve scroll behavior**

Verify that rows beyond the existing cap/visible height remain scrollable both before and after a range change. Only extend `StatusItemController+MenuCardInteractionPolicy.swift` if the nested detail view intercepts wheel events; use the existing forwarding seam rather than a new event monitor.

**Step 5: Run menu tests GREEN and commit**

Run:

```bash
swift test --filter MenuCardCursorRequestDetailsTests --filter MenuCardModelTests --filter MenuCardInteractionPolicyTests
```

Then commit:

```bash
git add Sources/CodexBar/MenuCardTokenDetailsView.swift Sources/CodexBar/MenuCardCursorTokenUsage.swift Sources/CodexBar/MenuCardView.swift Sources/CodexBarCore/UsageFormatter.swift Sources/CodexBar/StatusItemController+MenuCardInteractionPolicy.swift Tests/CodexBarTests/MenuCardCursorRequestDetailsTests.swift Tests/CodexBarTests/MenuCardInteractionPolicyTests.swift Tests/CodexBarTests/MenuCardModelTests.swift docs/cursor.md
git commit -m "feat(cursor): restore request detail diagnostics"
```

### Task 5: Add a typed OpenCode workspace-account core and discovery contract

**Files:**

- Create: `Sources/CodexBarCore/Providers/OpenCode/OpenCodeWorkspaceAccounts.swift`
- Create: `Sources/CodexBarCore/Providers/OpenCode/OpenCodeWorkspaceDiscovery.swift`
- Modify: `Sources/CodexBarCore/Config/CodexBarConfig.swift`
- Modify: `Sources/CodexBarCore/Providers/ProviderSettingsSnapshot.swift`
- Test: `Tests/CodexBarTests/OpenCodeUsageParserTests.swift`
- Create: `Tests/CodexBarTests/OpenCodeWorkspaceAccountsTests.swift`
- Create: `Tests/CodexBarTests/OpenCodeWorkspaceDiscoveryTests.swift`

**Step 1: Add failing pure-model tests**

Define a workspace account as one reusable OpenCode credential plus a stable workspace ID, label, optional owner label, timestamps, and active ID. Test:

- dedupe by `(tokenAccountID, workspaceID)`;
- pruning when the backing token account is removed;
- preserving the active workspace when valid;
- deterministic fallback to the first remaining account;
- workspace URL / `wrk_…` normalization.

**Step 2: Run core tests RED**

Run:

```bash
swift test --filter OpenCodeWorkspaceAccountsTests --filter OpenCodeWorkspaceDiscoveryTests
```

Expected: types and discovery contract do not yet exist.

**Step 3: Implement typed persistence and discovery**

- Add Codable, Sendable workspace-account data under the existing OpenCode provider configuration; no separate config file.
- Reuse the current OpenCode cookie import/header handling and injected `URLSession` test seam.
- Discover workspaces from the existing authenticated OpenCode account endpoint, returning only normalized workspace data—not raw cookies or responses.
- Surface an explicit result for saved, duplicate/no-op, missing reusable credential, invalid workspace ID, and discovery failure.

**Step 4: Run core tests GREEN and commit**

Run:

```bash
swift test --filter OpenCodeWorkspaceAccountsTests --filter OpenCodeWorkspaceDiscoveryTests --filter OpenCodeUsageParserTests
```

Then commit:

```bash
git add Sources/CodexBarCore/Providers/OpenCode/OpenCodeWorkspaceAccounts.swift Sources/CodexBarCore/Providers/OpenCode/OpenCodeWorkspaceDiscovery.swift Sources/CodexBarCore/Config/CodexBarConfig.swift Sources/CodexBarCore/Providers/ProviderSettingsSnapshot.swift Tests/CodexBarTests/OpenCodeWorkspaceAccountsTests.swift Tests/CodexBarTests/OpenCodeWorkspaceDiscoveryTests.swift Tests/CodexBarTests/OpenCodeUsageParserTests.swift
git commit -m "feat(opencode): add workspace account model"
```

### Task 6: Wire OpenCode workspaces through settings, menu, and refresh

**Files:**

- Create: `Sources/CodexBar/Providers/OpenCode/OpenCodeAccountsSection.swift`
- Modify: `Sources/CodexBar/Providers/OpenCode/OpenCodeProviderImplementation.swift`
- Modify: `Sources/CodexBar/SettingsStore+TokenAccounts.swift`
- Modify: `Sources/CodexBar/UsageStore+TokenAccounts.swift`
- Modify: `Sources/CodexBar/StatusItemController+Menu.swift`
- Modify: `Sources/CodexBar/ProviderRegistry.swift`
- Test: `Tests/CodexBarTests/SettingsStoreCoverageTests.swift`
- Test: `Tests/CodexBarTests/ProvidersPaneCoverageTests.swift`
- Create: `Tests/CodexBarTests/OpenCodeMenuCardTests.swift`
- Create: `Tests/CodexBarTests/OpenCodeStatusMenuTests.swift`

**Step 1: Add failing app-layer tests**

Test these user-facing outcomes:

- “Import current login” saves the imported credential and every discovered workspace, deduped;
- manual add accepts a workspace ID/URL only when a reusable credential exists;
- switching updates the active workspace before requesting the next OpenCode snapshot;
- missing/invalid discovery leaves typed fields intact and returns a clear notice;
- the menu shows a switcher only when more than one workspace account exists.

**Step 2: Run app-layer tests RED**

Run:

```bash
swift test --filter SettingsStoreCoverageTests --filter ProvidersPaneCoverageTests --filter OpenCodeMenuCardTests --filter OpenCodeStatusMenuTests
```

Expected: tests fail until the workspace-account settings and menu integration exist.

**Step 3: Implement the workspace-first settings flow**

- Add an OpenCode Accounts section with `Import current login`, `Refresh workspaces`, saved workspace list, active selection, and `Add workspace by ID`.
- Reuse a stored token account instead of asking users to paste a cookie per workspace.
- Persist selected workspace identity in the provider config and route the existing `OpenCodeUsageFetcher` through its workspace override.
- Refresh only the selected workspace after a switch; keep inactive workspace snapshots isolated by account identity.

**Step 4: Implement menu selection and scope guards**

- Use the existing token-account switcher presentation seam; do not replace `StatusItemController+Menu.swift` wholesale.
- Label each entry with the workspace/owner label, not secret-bearing cookie data.
- Keep OpenCode identities siloed: neither Cursor/Codex labels nor their usage can appear in OpenCode rows.

**Step 5: Run app-layer tests GREEN and commit**

Run:

```bash
swift test --filter SettingsStoreCoverageTests --filter ProvidersPaneCoverageTests --filter OpenCodeMenuCardTests --filter OpenCodeStatusMenuTests
```

Then commit:

```bash
git add Sources/CodexBar/Providers/OpenCode/OpenCodeAccountsSection.swift Sources/CodexBar/Providers/OpenCode/OpenCodeProviderImplementation.swift Sources/CodexBar/SettingsStore+TokenAccounts.swift Sources/CodexBar/UsageStore+TokenAccounts.swift Sources/CodexBar/StatusItemController+Menu.swift Sources/CodexBar/ProviderRegistry.swift Tests/CodexBarTests/SettingsStoreCoverageTests.swift Tests/CodexBarTests/ProvidersPaneCoverageTests.swift Tests/CodexBarTests/OpenCodeMenuCardTests.swift Tests/CodexBarTests/OpenCodeStatusMenuTests.swift
git commit -m "feat(opencode): restore workspace switching"
```

### Task 7: Add OpenCode widget switching and verify the complete change

**Files:**

- Modify: `Sources/CodexBar/UsageStore+WidgetSnapshot.swift`
- Modify: `Sources/CodexBarCore/WidgetSnapshot.swift`
- Modify: `Sources/CodexBarWidget/CodexBarWidgetProvider.swift`
- Modify: `Sources/CodexBarWidget/CodexBarWidgetViews.swift`
- Test: `Tests/CodexBarTests/CodexBarWidgetProviderTests.swift`
- Create: `Tests/CodexBarTests/OpenCodeWidgetSnapshotTests.swift`
- Update: `docs/opencode.md`
- Update: `docs/widgets.md`

**Step 1: Add failing widget tests**

Test that the snapshot has account ID/label for OpenCode entries and that switching with an App Intent changes only the selected workspace. A snapshot without the new optional fields must continue to decode.

**Step 2: Run widget tests RED**

Run:

```bash
swift test --filter CodexBarWidgetProviderTests --filter OpenCodeWidgetSnapshotTests --filter WidgetSnapshotTests
```

Expected: account identity and intent behavior fail before the widget wiring is added.

**Step 3: Persist only display-safe workspace identity**

Add optional `accountID` and `accountLabel` to `WidgetSnapshot.ProviderEntry`. For OpenCode, emit one entry per saved workspace with selected state; never serialize the workspace credential.

**Step 4: Add the minimal widget switcher**

- Add `SwitchWidgetOpenCodeWorkspaceIntent(accountID:)` using existing app-group defaults/settings synchronization.
- Show compact workspace buttons only for OpenCode with more than one saved workspace.
- Reload the widget after selection and preserve existing widget provider selection.

**Step 5: Run widget tests GREEN and commit**

Run:

```bash
swift test --filter CodexBarWidgetProviderTests --filter OpenCodeWidgetSnapshotTests --filter WidgetSnapshotTests
```

Then commit:

```bash
git add Sources/CodexBar/UsageStore+WidgetSnapshot.swift Sources/CodexBarCore/WidgetSnapshot.swift Sources/CodexBarWidget/CodexBarWidgetProvider.swift Sources/CodexBarWidget/CodexBarWidgetViews.swift Tests/CodexBarTests/CodexBarWidgetProviderTests.swift Tests/CodexBarTests/OpenCodeWidgetSnapshotTests.swift docs/opencode.md docs/widgets.md
git commit -m "feat(opencode): add workspace widget switcher"
```

### Task 8: Final documentation, integration verification, and review approval

**Files:**

- Modify: `docs/cursor.md`
- Modify: `docs/widgets.md`
- Modify: `docs/opencode.md`
- Modify: `docs/plans/2026-07-11-restore-cursor-widget-and-opencode-parity.md` only if implementation decisions materially change this plan

**Step 1: Document shipped behavior and boundaries**

- `docs/cursor.md`: exact versus approximate estimates, total-only/partial behavior, weighted request cost, range/period display, and request-based quota disclaimer.
- `docs/widgets.md`: Cursor selected-range summary/date range, schema compatibility, and OpenCode workspace switcher behavior.
- `docs/opencode.md`: import/discovery prerequisites, workspace-account storage, selection semantics, and no-credential exposure boundary.

**Step 2: Run formatting and focused checks**

Run:

```bash
swiftformat Sources Tests
swiftlint --strict
pnpm check
swift test --filter CursorModelNormalizerTests --filter CursorRequestCostReplayTests --filter CursorRequestCostEstimatorTests --filter CursorStatusProbeTests --filter CursorWidgetSnapshotTests --filter MenuCardCursorRequestDetailsTests --filter MenuCardInteractionPolicyTests --filter OpenCodeWorkspaceAccountsTests --filter OpenCodeWorkspaceDiscoveryTests --filter OpenCodeMenuCardTests --filter OpenCodeStatusMenuTests --filter OpenCodeWidgetSnapshotTests --filter CodexBarWidgetProviderTests --filter WidgetSnapshotTests
git diff --check
```

Expected: no formatter/linter/check failures; focused tests pass; diff check is clean.

**Step 3: Build and run the actual bundle**

Run:

```bash
CODEXBAR_SIGNING=adhoc ./Scripts/compile_and_run.sh --wait
ps -ax -o pid=,etime=,comm= | rg 'CodexBar(\\.app/Contents/MacOS/CodexBar)?$'
```

Expected: a real `CodexBar.app/Contents/MacOS/CodexBar` PID remains alive. Verify the reviewed bundle rather than accepting the launcher’s process match.

**Step 4: Obtain independent code-review approval**

Run the Codex Review Loop with the `gpt-5.6-terra` model against the final branch diff. Address confirmed findings, rerun the affected checks, and repeat until the review returns `APPROVED`.

**Step 5: Commit documentation and final verification evidence**

```bash
git add docs/cursor.md docs/widgets.md docs/opencode.md docs/plans/2026-07-11-restore-cursor-widget-and-opencode-parity.md
git commit -m "docs: record restored Cursor and OpenCode behavior"
```

Before the commit, print the required documentation marker:

```text
[DOCS UPDATED: docs/cursor.md, docs/widgets.md, docs/opencode.md, docs/plans/2026-07-11-restore-cursor-widget-and-opencode-parity.md]
```

