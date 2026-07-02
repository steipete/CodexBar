# Overview Scroll Stutter Investigation

Status: draft context for external review  
Date: 2026-06-20  
Related issue: https://github.com/steipete/CodexBar/issues/1674  
Candidate PRs:

- Lite row: https://github.com/steipete/CodexBar/pull/1675
- Rich row: https://github.com/steipete/CodexBar/pull/1676

## Purpose

This document explains the motivation, evidence, design split, current PR state, and open review questions for the CodexBar Overview menu scroll-stutter work. It is written as a handoff document for a second reviewer, especially Claude, to review both the reasoning and the patch directions without needing to reconstruct the whole GitHub thread.

The core question is not only "does either patch compile?" The real question is whether we chose the right boundary for reducing scroll-time work inside an `NSMenu` that hosts rich SwiftUI rows.

## Original Problem

The user-reported symptom is severe scroll jank in the CodexBar home / Overview menu. The problem appears on recent CodexBar builds and on multiple remote latest versions, not just one local install.

Observed environment from the local sample:

```text
CodexBar 0.37.0 (90)
macOS 27.0 (26A5353q)
Main-thread sample duration: 8 seconds, 1 ms interval
Main-thread sample count: 3440
Physical footprint: 211.4M, peak 255.3M
```

The user described the behavior as "每次滚动的时候都会卡" while the Overview tab has multiple providers enabled. The screenshot shows the Overview tab with rich provider cards, usage bars, quota sections, cost/token history, and multiple provider entries below.

## Evidence From The Sample

The redacted sample summary points at menu tracking and SwiftUI row rendering/layout, not provider refresh or token-cost scanning.

Relevant sample counts:

```text
2222 -[NSMenuTrackingSession startRunningMenuEventLoop:]
91   -[NSContextMenuImpl _reloadData]
19   -[NSContextMenuImpl _menuBackingViewDidChangeIntrinsicSizeWithAnimation:]
23   ViewGraphRootValueUpdater.render
12   NSHostingView.hitTest
9    LazyVGridLayout lengthAndSpacing
6    -[NSView scrollWheel:]
```

The important interpretation is that scroll input seems to stay inside the `NSMenuTrackingSession` hot path, where AppKit repeatedly re-enters hosted SwiftUI row layout/render/hit-test work. That fits the visible symptom: jank occurs on every scroll event, even without a provider refresh being initiated.

Two caveats a reviewer should keep in mind about how strong this sample is:

- The `2222 startRunningMenuEventLoop` frame is the **parent** frame of all menu-tracking activity (including idle waiting), not a leaf hotspot. The meaningful work is in the much smaller leaf counts (`_reloadData 91`, `render 23`, `hitTest 12`, `LazyVGridLayout 9`). Relative to 3440 total samples, the main thread is not pegged continuously, so the jank is more consistent with **bursty per-scroll-event frame hitches** than sustained CPU saturation. This is suggestive, not conclusive — an Instruments time-profiler trace correlating scroll events with dropped frames would be the stronger proof (see "What Is Not Proven").

- Reading `StatusItemController+OverviewScroll.swift` makes the likely mechanism concrete. `postOverviewScrollNavigation` does two things per highlight step: it calls `self.menu(menu, willHighlight: target)` to advance highlight state immediately, **and then** posts a synthetic `.mouseMoved` event over the target row's center. On `main`, the highlight-state flip re-renders the full SwiftUI row through `MenuCardSectionContainerView` (`.environment(\.menuItemHighlighted)` + `.foregroundStyle(primary(highlighted))` + a conditional background), and the synthetic mouse-move makes AppKit re-run hit-testing down into the hosted SwiftUI tree (`NSHostingView.hitTest`). So each scroll step costs roughly **two full rich-row re-renders (old + new highlight) plus a hit-test descent**, and a single flick emits up to three steps. That double-re-render-per-step is the most plausible source of the stutter, and it is exactly the link both PRs cut at different points.

## Source Mapping

The sample stack maps cleanly onto current `origin/main` around commit `8c4bdd63f3d6d1432fcdb50add7ed6988a2b5734`.

Key source paths:

- `Sources/CodexBar/StatusItemController+Menu.swift`
  - `addOverviewRows` builds each Overview provider row as a custom menu card.
  - It installs provider-detail submenus and click handling.
- `Sources/CodexBar/StatusItemController+MenuTypes.swift`
  - `OverviewMenuCardRowView` is the SwiftUI view rendered inside each Overview row.
  - It subscribes to menu highlight environment.
- `Sources/CodexBar/MenuCardView.swift`
  - `UsageMenuCardUsageSectionView` renders usage content.
  - It resolves live menu-card models through `MenuCardRefreshMonitor`.
- `Sources/CodexBar/InlineUsageDashboardContent.swift`
  - Uses `LazyVGrid` and mini chart/bar content.
  - This matches the `LazyVGridLayout lengthAndSpacing` sample fragment.
- `Sources/CodexBar/StatusItemController+OverviewScroll.swift`
  - Handles scroll-wheel navigation on Overview rows.
  - Moves highlight by calling menu highlight paths and posting synthetic mouse movement over row views.

This led to the working hypothesis:

> The Overview tab keeps several rich SwiftUI provider cards inside an `NSMenu`; scroll/highlight/hit-test re-enters layout and rendering for those hosted rows. The hot path is row presentation and menu tracking, not provider data fetching.

## Issue Work

We opened issue #1674:

https://github.com/steipete/CodexBar/issues/1674

Title:

```text
v0.37.0: Overview menu stutters on every scroll event with multiple providers on macOS 27
```

The issue includes:

- Repro environment.
- Sample summary.
- Source mapping from sample stack to current main.
- Two proposed fix directions.
- Explicit note that the full sample file was not uploaded because it includes local machine paths.

We also cc'd two earlier participants, `@Astro-Han` and `@elkaix`, in a comment on #1674 because both had described detailed menu lag in earlier issues. To be precise about attribution: `@Astro-Han` commented on #1196 (which was authored by `@vekovius`), and `@elkaix` authored #1414. The mention was intentionally limited to people with directly related prior reports, following maintainer-radar guidance.

Note one internal inconsistency in the thread: the #1674 issue body cites the older reports as #1196, #1371, and #1387, while the cc comment (and the framing above) pairs #1196 with #1414. Both reference real prior lag reports; the difference is only which subset each surface lists.

ClawSweeper kept the issue open. The full current label set (as of this update) is:

- `P2`
- `clawsweeper:needs-live-repro`
- `clawsweeper:needs-maintainer-review`
- `clawsweeper:needs-product-decision`
- `clawsweeper:no-new-fix-pr`
- `issue-rating: 🐚 platinum hermit`
- `impact:other`

The `clawsweeper:no-new-fix-pr` label is worth calling out for a reviewer: ClawSweeper does **not** recommend queueing an *automated* fix PR for this issue. The two draft PRs below are human-authored exploratory directions opened deliberately for the maintainer product decision, not automated fixes — so they are consistent with, not contradicted by, that label.

Its acceptance criteria included:

```text
swift test --filter StatusMenuOverviewScrollTests
swift test --filter MenuCardViewRecyclingTests
swift test --filter StatusMenuOverviewSubmenuTests
make check
On macOS 27, run a freshly built app with multiple Overview providers and capture before/after scroll profiling or visual proof.
```

## Why Two PRs

There are two plausible fixes, but they make different product and engineering tradeoffs. Mixing them in one patch would make review unclear.

So we opened two draft PRs as alternatives, not as cumulative patches:

1. #1675: Lite row
2. #1676: Rich row with AppKit boundary

Both PRs are draft PRs because maintainers still need to choose the desired UI/performance direction before merge.

## PR #1675: Lite Row

PR: https://github.com/steipete/CodexBar/pull/1675  
Branch: `codex/overview-lite-row`  
Latest head at the time of this document: `6f680eeb18e37fb329cf7c26b956ded8c967a076`

### Motivation

If the root problem is too much hosted SwiftUI content inside the Overview menu, the lowest-risk performance path is to render less content in each Overview row.

The Lite row direction keeps Overview as a quick provider summary:

- Provider identity.
- Updated/subtitle state.
- Plan/account/storage text where relevant.
- A compact quota summary.
- Existing click and submenu behavior.

It intentionally moves rich charts/details out of the Overview row and leaves them in provider detail surfaces.

### Implementation Summary

Changed files:

- `Sources/CodexBar/StatusItemController+MenuTypes.swift`
- `Tests/CodexBarTests/OverviewMenuCardRowViewTests.swift`

Key implementation points:

- Replaced the rich `UsageMenuCardHeaderSectionView` + `UsageMenuCardUsageSectionView` Overview composition with a compact summary row.
- Added `LiteSummary`, which derives a bounded summary from precomputed `UsageMenuCardView.Model` fields.
- Explicitly avoids rendering `InlineUsageDashboardContent` in Overview rows.
- Preserves provider click behavior and provider-detail submenus.
- Preserves live subtitle and model refresh semantics through `MenuCardRefreshMonitor`.

### ClawSweeper Finding And Fix

ClawSweeper's concrete code finding was:

> Use the live model for the compact summary.

The first Lite row patch updated the subtitle through `MenuCardRefreshMonitor`, but built the compact summary and progress tint from `self.model`. That could produce a stale quota/progress summary while the subtitle had already refreshed.

Follow-up fix:

- Added `resolvedLiveModel(refreshMonitor:)`.
- Header, compact summary, and progress tint now all derive from the same monitor-resolved model.
- Added focused coverage proving a stale row resolves refreshed progress through the monitor without rebuilding the menu.

New focused test:

```text
overview lite summary uses monitor resolved refreshed model
```

### Validation

Local validation run for the Lite row direction:

```text
swift test --filter OverviewMenuCardRowViewTests
swift test --filter "overview row"
swift build
make check
git diff --check
```

The PR body and follow-up comment were updated, and `@clawsweeper re-review` was requested. ClawSweeper acknowledged the re-review command for head `6f680eeb`.

### Risks

The Lite row direction changes the product feel of Overview. It likely reduces scroll-time work, but it also removes rich chart/detail content from the Overview list. This needs maintainer/product approval.

It still lacks an interactive after-fix scroll profile or recording.

## PR #1676: Rich Row With AppKit Boundary

PR: https://github.com/steipete/CodexBar/pull/1676  
Branch: `codex/overview-rich-row`  
Latest head at the time of this document: `963ed4cf9941cc98300650c5532e7ffcebf1b618`

### Motivation

If maintainers want to preserve the current rich Overview UI, we should reduce scroll/hover overhead without removing content.

The suspected expensive interaction is SwiftUI highlight/hit-test/layout work during `NSMenu` tracking. The rich-row direction therefore keeps the SwiftUI content but moves row-level hover/highlight/hit-test handling to a narrow AppKit wrapper.

### AppKit Boundary

This direction uses a small AppKit bridge:

- SwiftUI still owns the row content and model rendering.
- SwiftUI still receives `menuCardRefreshMonitor`.
- AppKit owns only row-level:
  - `hitTest`
  - hover background via `CALayer`
  - measured/fixed row height behavior
  - recycling support
  - click glue

This follows the `build-macos-apps:appkit-interop` guidance: cross only the narrow platform boundary needed for menus instead of rewriting the feature in raw AppKit.

### Implementation Summary

Changed files:

- `Sources/CodexBar/StatusItemController+Menu.swift`
- `Sources/CodexBar/StatusItemController+MenuCardItems.swift`
- `Sources/CodexBar/StatusItemController+MenuPresentation.swift`
- `Sources/CodexBar/StatusItemController+MenuTypes.swift`
- `Tests/CodexBarTests/MenuCardViewRecyclingTests.swift`

Key implementation points:

- Added `OverviewMenuRowHostingView`, an AppKit host for Overview rows only.
- Added `makeOverviewMenuRowItem` so normal menu cards keep the existing path.
- Moved row highlight to an AppKit `CALayer`.
- Made `hitTest` stop at the Overview row container boundary.
- Preserved provider click behavior and provider-detail submenus.
- Preserved `MenuCardRefreshMonitor` injection through `OverviewMenuRowContainerView`.
- Guarded repeated intrinsic-size invalidation when row height does not change.

### Follow-up Test

ClawSweeper did not report a concrete code defect for #1676. It mainly requested real behavior proof.

We still added one lifecycle regression test after re-reviewing the AppKit bridge:

```text
recycled overview row keeps hosting view and clears appkit highlight state
```

This verifies that:

- The hosting view is recycled instead of rebuilt.
- Stale AppKit highlight state is cleared during reuse.

### Validation

Local validation run for the Rich row direction:

```text
swift test --filter "overview row"
swift test --filter "highlight"
swift build
make check
git diff --check
CODEXBAR_SIGNING=adhoc ./Scripts/package_app.sh debug
codesign --verify --deep --strict --verbose=2 CodexBar.app
```

The follow-up validation was run on:

```text
macOS 27.0 (26A5353q)
Apple Swift 6.4
arm64
```

The PR body and follow-up comment were updated, and `@clawsweeper re-review` was requested. ClawSweeper acknowledged the re-review command for head `963ed4cf`.

### Risks

The Rich row direction preserves UI density but adds a new AppKit hosting boundary. The bridge is intentionally narrow, but it touches primary menu rendering and interaction. The main residual risk is runtime behavior under a real `NSMenuTrackingSession`.

Two specific risks a reviewer should weigh, beyond runtime behavior:

- **Highlight appearance changes (an undisclosed visual regression).** The new `makeOverviewMenuRowItem` wraps content in `OverviewMenuRowContainerView`, which injects only `menuCardRefreshMonitor` — it does **not** inject `menuItemHighlighted`, does not apply `foregroundStyle(primary(highlighted))`, and does not draw the SwiftUI selection background that `MenuCardSectionContainerView` provides on the existing path. Because the rich header/usage subviews all read `@Environment(\.menuItemHighlighted)` (see `MenuCardView.swift`), that environment now stays `false`, so the row text **no longer inverts on highlight**. Highlight is conveyed only by the `CALayer` background (`selectedContentBackgroundColor` at alpha `0.16`). Net effect: an Overview row highlights as a faint translucent background with dark text, while every other row/submenu in the same menu still uses the standard solid-blue-with-white-text selection — an inconsistent, weaker highlight. The captured `cgColor` is also static and will not follow accent-color or light/dark changes. This is a product-visible change that the PR body currently frames as a neutral "move hover highlight to a cheap CALayer"; it should be disclosed and accepted explicitly.

- **Duplicated hosting infrastructure.** `OverviewMenuRowHostingView` re-implements much of the existing `MenuCardItemHostingView` (`installClickRecognizer`, `acceptsFirstMouse`, `measuredHeight`, `prepareForReuse`, `allowsVibrancy`), creating two parallel menu-hosting classes to maintain. Reusing or parameterizing the existing host would be a lower-divergence design.

It still lacks an interactive after-fix scroll profile or recording.

## Current GitHub State

As of the latest local `gh` check:

- Issue #1674 is open.
- PR #1675 is open and draft.
- PR #1676 is open and draft.
- Both PRs are mergeable.
- Both PRs have follow-up commits pushed.
- Both PRs have ClawSweeper re-review queued and acknowledged.
- GitGuardian has passed on both updated heads.
- Other GitHub Actions checks may still be queued or not yet refreshed for the latest heads.

We intentionally did not wait synchronously for all external checks, because the local proof, PR body updates, and ClawSweeper re-review requests are already done.

## What Is Proven

The issue is high-quality enough to keep open:

- The user supplied a concrete symptom and sample command.
- The sample maps to current source.
- The suspect stack is tied to menu tracking and hosted SwiftUI row layout/render/hit-test.
- The current source has not meaningfully changed in the implicated files after v0.37.0.

The Lite PR proves:

- Overview row content can be made lightweight.
- Dashboard-heavy SwiftUI content is avoided in Overview rows.
- The compact summary uses the same monitor-resolved live model as existing usage-row logic.
- Click/submenu behavior remains covered by existing Overview tests.

The Rich PR proves:

- Overview can keep the rich row UI while moving highlight/hit-test to AppKit.
- AppKit highlight state is cleared on reuse.
- Overview row hosting views can be recycled.
- Existing overview row action, submenu, rendered-mode, storage text, and scroll targeting tests continue to pass.
- A debug app package can be produced and codesigned locally on macOS 27.

## What Is Not Proven

We still do not have the strongest proof ClawSweeper asked for:

- No controlled before/after interactive scroll recording.
- No after-fix `sample` output captured while scrolling a provider-heavy Overview menu.
- No Instruments trace showing frame-time or main-thread stack reduction.

This is important because unit tests can prove the row model and bridge lifecycle, but they cannot fully simulate `NSMenuTrackingSession` behavior under real trackpad/mouse-wheel input.

## Smaller Third Direction (Candidate)

Both PRs are fairly large for a performance fix. Given the mechanism in "Evidence From The Sample" (each scroll step costs two full rich-row re-renders plus a hit-test descent), there are two smaller, lower-commitment experiments worth trying before settling on either PR:

1. **Decouple highlight from content re-render, SwiftUI-only.** Make the selection background the *only* thing that depends on the highlight flag, and stop re-coloring the whole subtree via `foregroundStyle(primary(highlighted))` at the container level. This is the SwiftUI-subset of what the Rich PR does in AppKit: it cuts the per-highlight re-render cost without introducing a new `NSView` host class and without changing the highlight's visual style (the background can keep using the standard selection color).

2. **Drop the redundant synthetic mouse-move.** `postOverviewScrollNavigation` already advances highlight explicitly via `self.menu(menu, willHighlight:)`; the subsequent synthetic `.mouseMoved` then re-drives hit-testing and highlighting (the `NSHostingView.hitTest` / `scrollWheel` work in the sample). The code comment says the mouse-move preserves native highlight/submenu behavior, so this needs a targeted experiment to confirm it is actually redundant — but if it is, removing it is a ~10-line change that hits the hit-test path directly.

Both still require the same controlled macOS 27 interactive profiling to confirm. The Rich PR is essentially the industrial-strength version of option 1; option 2 is orthogonal and could stack with either PR.

## Design Tradeoff

The maintainer decision is likely between these two philosophies:

### Choose Lite Row If

- Overview should be a fast high-level summary.
- Full charts/details can live in provider detail surfaces.
- Reducing SwiftUI content is preferred over preserving exact current density.
- The simplest performance path is preferred.

### Choose Rich Row If

- Overview should preserve the current information density.
- The performance problem is mostly hover/hit-test/highlight propagation.
- A narrow AppKit menu boundary is acceptable.
- Maintainers want a lower visual-change patch.

These PRs should not both merge. If maintainers choose one direction, the other should be closed or parked.

## Recommended Next Steps

1. Wait for ClawSweeper re-review to finish on both PRs.
2. If ClawSweeper clears the concrete Lite finding, compare remaining comments.
3. Run one controlled interactive proof on macOS 27:
   - Build a fresh app from the chosen branch.
   - Enable multiple Overview providers.
   - Open Overview.
   - Scroll while recording a short video or running `sample`.
   - Redact local paths/account info before posting summary.
4. Ask maintainers to choose Lite vs Rich based on UI preference and proof.
5. Convert only the selected PR from draft to ready.

## Questions For Claude Review

Please review the two PR directions and this reasoning with these questions in mind:

1. Is the root-cause interpretation coherent from the sample stack and source mapping?
2. Does the Lite row PR fix ClawSweeper's live-model critique completely, or is there another stale-model path?
3. Does the Rich row AppKit bridge cross the smallest reasonable boundary, or does it introduce hidden lifecycle risk?
4. Are there tests missing that would materially increase confidence without requiring a real interactive menu session?
5. Between Lite and Rich, which direction is more likely to be accepted by maintainers, and why?
6. Is there a third direction that is smaller than both PRs and still addresses the scroll hot path?
7. Are the PR bodies honest and precise about what is proven versus what remains unproven?

## Review Pointers

The symbols and test files below are introduced by the PR branches and do **not** exist on `main` (where this document lives). Check out the relevant branch or read the PR diff before following these pointers:

- Lite row: `git checkout codex/overview-lite-row` (PR #1675) — adds `LiteSummary`, `resolvedLiveModel(refreshMonitor:)`, and `OverviewMenuCardRowViewTests`.
- Rich row: `git checkout codex/overview-rich-row` (PR #1676) — adds `OverviewMenuRowHostingView`, `makeOverviewMenuRowItem`, and `OverviewMenuRowContainerView`.

On `main`, only the unchanged baseline symbols (`addOverviewRows`, `OverviewMenuCardRowView`, `UsageMenuCardUsageSectionView`) are present.

For Lite row review:

- Start with `OverviewMenuCardRowView` in `Sources/CodexBar/StatusItemController+MenuTypes.swift`.
- Check `resolvedLiveModel(refreshMonitor:)`.
- Check `LiteSummary.make(for:)`.
- Check `OverviewMenuCardRowViewTests`.

For Rich row review:

- Start with `OverviewMenuRowHostingView` in `Sources/CodexBar/StatusItemController+MenuPresentation.swift`.
- Check `makeOverviewMenuRowItem` in `Sources/CodexBar/StatusItemController+MenuCardItems.swift`.
- Check `addOverviewRows` in `Sources/CodexBar/StatusItemController+Menu.swift`.
- Check `MenuCardViewRecyclingTests`.

For shared behavior:

- Check `StatusMenuOverviewScrollTests`.
- Check `StatusMenuOverviewSubmenuTests`.
- Check existing menu-card recycling behavior.

## Bottom Line

The motivation is solid: a real user-visible scroll stutter maps to a plausible current-source hot path in `NSMenu` plus hosted SwiftUI Overview rows.

The progress is also concrete: the issue is public, two alternative draft PRs exist, ClawSweeper feedback was addressed where it identified real code problems, and both branches have focused tests plus local validation.

The main unresolved question is not "can we patch something?" It is which product/performance tradeoff maintainers want, and whether a controlled macOS 27 interactive scroll proof confirms the chosen direction.

---

## Update 2026-06-24: Measured root cause + a third (implemented) direction

This section adds quantitative evidence collected on macOS 27 (Swift 6.4, debug) and a third
implementation that supersedes the lite/rich split for the render half of the problem.

### Headless benchmark of one highlight step

Scrolling the Overview does not scroll pixels — `handleOverviewScrollWheel` converts the wheel into
discrete "move the highlighted row" steps. So the per-scroll cost is the cost of toggling a row's
selection. A headless benchmark hosted a real `OverviewMenuCardRowView` through the production
hosting path and measured `setHighlighted → layout → display → runloop-flush` over 200 toggles:

```text
A baseline (SwiftUI recolor via menuItemHighlighted)   avg ~2.4–10ms  max ~7–27ms
B + .drawingGroup() (Metal offscreen rasterization)    avg ~2.2–10ms  max ~9–32ms  (~10–28% only)
C content pinned, highlight fully decoupled            avg ~0.01–0.06ms
D container highlight modifiers only, content pinned   avg ~3–8ms
E GPU CIColorMatrix tint + AppKit selection layer      avg ~0.05ms     max ~1–2ms
```

Findings:

- The spikes in `A` (~25ms) line up with the dropped frames in the user's recording (120fps capture,
  ~57fps effective, worst frame gaps ~25ms).
- `D` shows the cost is dominated by re-rasterizing the content subtree whenever the container's
  highlight-dependent modifiers change — not by leaf body evaluations.
- `B` proves **Metal alone is insufficient**: `.drawingGroup()` speeds rasterization but the SwiftUI
  body/transaction pass still runs, so it only buys ~10–28% and still misses the 8.3ms/120Hz budget.
- `E`/`C` show the only way to the 120Hz budget is to take the selection off the SwiftUI graph.

### Implemented direction: AppKit/GPU selection (`GPUSelectionHostingView`)

`Sources/CodexBar/MenuCardGPUSelectionView.swift` renders the selected look without any SwiftUI work:

1. an `NSVisualEffectView(.selection)` background (the existing in-repo pattern from
   `PersistentRefreshMenuView`), crossfaded via Core Animation so the highlight glides between rows
   instead of teleporting, and
2. a `CIColorMatrix` content filter that maps the row's pixels to the selected text color — which
   matches the existing design where every selected element already becomes
   `selectedMenuItemTextColor`. Core Image runs on the GPU (Metal), so the toggle is a layer change.

It is opt-in via `makeMenuCardItem(usesGPUSelection:)` and currently wired only for Overview rows in
`addOverviewRows`. It deliberately does **not** override `hitTest`, avoiding the embedded-control
regression ClawSweeper flagged on the rich-row PR. Measured production path: **2.35ms → 0.044ms**
average per toggle, max well under one 120Hz frame.

### The second, orthogonal problem: discrete navigation feel

Even at 0.05ms/step, the motion is not "hand-following" because the wheel is quantized. Driving the
real `handleOverviewScrollWheel` with continuous gestures showed:

```text
slow swipe:  240px finger travel -> one row jump every 24px (teleport, nothing in between)
fast flick:  200px (intent ~8 rows) -> only 3 rows registered (per-event cap + remainder discarded)
post-flick 20px nudge -> 0 steps (accumulator was zeroed, so the follow-up felt dead)
```

Interaction changes in `StatusItemController+OverviewScroll.swift` (merged with a parallel Codex
worktree that independently reached the same GPU-selection design):

- **Precise trackpad scrolls are passed through to AppKit's native menu scroller** instead of being
  converted into thresholded row-highlight jumps (`guard !event.hasPreciseScrollingDeltas { … return
  false }`). Trackpads are continuous devices; native menu scrolling follows the finger, which is the
  real fix for the "不跟手" feel — making highlight toggles cheap (above) does not by itself remove the
  discrete-jump model. Classic notched scroll wheels keep the row-to-row highlight navigation.
- The crossfade in `GPUSelectionHostingView` softens the remaining wheel-driven highlight transitions.

A deterministic regression test (`gpu selection highlight bypasses swiftui highlight state`) asserts
that highlighting a GPU row marks the AppKit view highlighted while the hosted
`MenuCardHighlightState.isHighlighted` stays `false`, proving selection never re-invalidates the
SwiftUI graph.

### Test status

`swift build` clean; the updated `StatusMenuOverviewScrollTests` (precise pass-through cases) and the
menu-card recycling/highlight suites — including the new GPU bypass test — pass.
