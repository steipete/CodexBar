---
summary: "Approved opt-in compact layout for the merged menu's Overview tab."
read_when:
  - Implementing or reviewing compact Overview rows
  - Changing Overview provider selection, row height, or menu refresh behavior
  - Changing which usage-bar details appear in the merged menu
---

# Compact Overview menu — design

**Status:** implemented
**Date:** 2026-07-30
**Revised:** 2026-07-31

## Decision summary

Add an opt-in **Compact Overview** setting for the merged menu. Detailed Overview remains the default.

Compact Overview keeps the existing Overview provider selection, ordering, navigation, refresh, and submenu behavior,
but replaces each rich provider card with one actionable provider item containing:

- a dedicated provider-name header row; and
- every drawable usage metric beneath that header, in the provider's existing
  `UsageMenuCardView.Model.metrics` order.

Each bar keeps a short metric label so multiple windows remain distinguishable. Visible numeric percentages are
omitted; the progress bar retains the existing percentage and used-versus-left accessibility semantics. Account identity,
freshness, plan, reset time, details, storage, notes, dashboards, and dedicated credit or cost sections stay available
in provider details but do not appear inline in Compact Overview. A provider with no drawable metric uses one muted,
single-line fallback beneath its header so the row does not look unfinished; that fallback may surface an existing
status-only balance metric.

“All bars” means all drawable bars for the providers selected for Overview. The existing six-provider selection limit
does not change in this feature.

For this feature, a **drawable metric** is exactly a `UsageMenuCardView.Model.metrics` entry whose `statusText` is
`nil`. The existing model builder remains responsible for producing a valid percentage, title, and semantic metric;
Compact Overview adds no provider-specific or numeric filtering. Credits, cost, storage, reset credits, and inline
dashboards are separate model sections rather than compact metrics and remain excluded.

## Why this needs a bounded design

The current Overview row is effectively a full provider card. It composes the two-line provider header, full metric
rows, reset and detail text, optional notes or dashboards, and optional storage text. Six providers can therefore make
the menu taller than the available display and require scrolling.

The desired compact mode is presentation-only, but Overview is also coupled to:

- persisted provider selection and a six-provider cap;
- live model updates while an `NSMenu` is tracking;
- measured-height caching;
- provider-detail submenus and click-to-select behavior;
- custom wheel navigation and native trackpad scrolling; and
- GPU-backed row selection added after the Overview scroll-stutter investigation.

A dedicated contract prevents a small layout option from accidentally changing those established behaviors. The
performance history and earlier Lite-row experiment are documented in
[`docs/overview-scroll-stutter-investigation.md`](../../overview-scroll-stutter-investigation.md).

## Goals

- Let users compare the selected providers' usage bars at a glance.
- Keep the normal six-provider Overview substantially shorter than Detailed while using comfortable, legible text and
  bars; prefer a small amount of native scrolling over making the content uncomfortably small.
- Preserve every actual metric bar rather than silently choosing one window per provider.
- Keep the current detailed Overview unchanged for users who do not opt in.
- Reuse the existing menu-card model, progress renderer, live-refresh seam, and interaction wiring.
- Keep the implementation display-only: no new fetches, dependencies, account state, or provider-specific data paths.

## Non-goals

- Showing every enabled provider. Overview continues to show at most six user-selected providers.
- Guaranteeing a scroll-free menu for every display, Accessibility text size, or provider response.
- Capping or dropping bars merely to force the menu to fit.
- Changing provider order, Overview selection, switcher contents, row click behavior, or detail submenus.
- Compacting individual provider tabs, Settings provider details, widgets, or menu-bar icons.
- Adding new provider-specific credit, cost, storage, or inline-dashboard projections. The generic no-bar fallback may
  reuse an existing redacted metric `statusText`, but it does not inspect provider snapshots or rich-card sections.
- Revisiting the existing Overview GPU-selection or scroll implementations.

## User experience

### Setting

Preferences → Menu → Content gains a toggle as the first content-layout option:

- **Title:** Compact Overview
- **Subtitle:** Show provider names and usage bars in a space-saving layout.

The Overview provider selector remains in Preferences → Menu Bar → Combined Icon. Only the presentation toggle
moves to the Menu pane, because it controls menu content rather than the menu-bar status item. The toggle is disabled
when **Merge Icons** is off because Overview is not then available. Its stored value is retained, so re-enabling Merge
Icons restores the user's choice.

The setting defaults off for both existing and new installations. No migration is required.

### Compact row

Each provider is one actionable menu item. Inside it, the provider name occupies a dedicated full-width header row and
the metric lanes are stacked underneath:

```text
Codex                                         ›
Session            ███████░░░
Weekly             ███░░░░░░░

Claude                                        ›
Session            █████░░░░░
Weekly             ████████░░
```

This is a layout illustration, not fixed copy. Localized metric titles and the existing used/remaining preference
remain authoritative.

Each metric lane contains only:

1. the existing localized metric title;
2. the existing `UsageProgressBar`.

Do not render a percentage `Text` view or reserve a percentage column. The existing used/remaining preference remains
authoritative for bar fill and accessibility. `UsageProgressBar` continues to expose the formatted percentage together
with its localized `Usage remaining` or `Usage used` meaning to assistive technologies.

The provider header spans the content width up to the fixed trailing chevron gutter; it is not part of the metric grid.
The chevron aligns vertically with the provider header. Every selected provider uses the same metric-label and bar
column widths. Long provider and metric names truncate to one line while preserving their full accessibility text. The
bar does not compress until the metric label reaches its cap.

Provider rows are variable-height. A provider with one drawable metric gets one lane, a provider with `N` drawable
metrics gets exactly `N` lanes, and a provider with no drawable metrics gets one fallback lane. Do not reserve an empty
second lane, cap a row at two lanes, collapse additional lanes, or repeat the provider header. Keep vertical padding,
header-to-metrics spacing, lane height, and lane spacing in the compact-layout constant group. At default text size, a
one-lane or fallback hosted item should remain at most 54 points including the existing seven-point AppKit measurement
inset, and each additional lane should add at most 20 points. Attached-menu tests remain authoritative because AppKit
can prefer intrinsic height over the assigned frame.

The 310-point minimum-width budget is:

| Element | Budget |
| --- | ---: |
| Outer horizontal padding | 40 pt (`20 pt × 2`) |
| Metric-to-bar spacing | 12 pt |
| Metric label | up to 112 pt |
| Minimum progress bar | 146 pt |
| **Total** | **310 pt** |

At 310 points and default text size, cap the shared metric column at 112 points. The allocator may reclaim unused metric
label width for the bar, but it must never give one row a different metric/bar split. At wider resolved menu widths,
keep the label cap, padding, and gap fixed and give all surplus width to the bar. The 12-point chevron gutter is carved
out of the provider header's 270-point content width; metric lanes span that full width below the header.

Use `.headline` for the provider header and `.body` for the metric title. Use logical leading alignment for both.
Vertically center an eight-point progress bar in each metric lane. Use four points of vertical padding on each edge,
four points between the header and first metric, and three points between subsequent lanes. Keep these values in one
compact-layout constant group.

The allocator's supported input is the production invariant `menuWidth >= 310`; assert that precondition in DEBUG and
unit tests rather than inventing an unreachable below-minimum layout. Measure metric titles with the resolved body
font and cap their shared selected-set maximum at 112 points. That fixed cap and the other fixed reservations guarantee
the 146-point bar floor at 310 points even when text scale changes; larger text truncates visually at the cap and keeps
its full accessibility string. If a future design adds or enlarges a fixed reservation, update this budget and the
production minimum together instead of allowing overlap or horizontal scrolling.

The submenu chevron is currently an overlay rather than a layout participant. Reserve its gutter in every provider
header, including rows without a submenu, so headers align and cannot overlap the indicator. Because the indicator is
header-aligned, metric lanes below it may use the full content width.

Compact rows use comfortable but still economical vertical spacing and keep the current separators between providers.
They do not add another scroll container; AppKit remains responsible if the whole menu exceeds the display.

### Content rules

Compact Overview first preserves the existing menu-build exclusion for `model.isOverviewErrorOnly`. It then renders,
in order, only metrics with `statusText == nil`. A metric with non-`nil` `statusText` is text-only in the current rich
card and must be omitted from the bar lanes rather than converted into a synthetic empty or full bar. It may be used
only by the no-drawable-metric fallback defined below.

For each drawable metric, preserve:

- `percent` and `percentStyle`;
- provider tint;
- pace percentage and pace direction;
- quota-warning marker percentages; and
- workday marker percentages.

Compact Overview omits inline:

- email, organization, workspace, and other account identity;
- update/loading/error subtitle and copy button;
- plan;
- reset time and all secondary/detail/session-equivalent lines;
- storage footprint;
- usage notes and placeholders;
- inline usage dashboards and charts;
- reset credits, dedicated credit-balance, provider-cost, and token-cost sections; and
- metric card backgrounds or other rich-card decoration.

If a selected provider has no drawable metrics but is not excluded by the existing error-only rule, show its provider
header plus one muted, single-line fallback beneath it:

1. when `model.subtitleStyle == .loading`, show `L("Loading…")`;
2. otherwise, trim each metric's `statusText` with `.whitespacesAndNewlines` and, if any result is non-empty, use the
   first such metric in model order; or
3. otherwise show the localized compact no-bars string.

For a status fallback, put the metric title in the shared metric column and let its trimmed status text occupy the bar
column. For loading or generic no-bars fallback, let the one fallback string span the metric and bar columns. Use
`.body`, secondary styling, leading alignment in the current layout direction, and
`.lineLimit(1)` for fallback text. This avoids hard-coded English punctuation or word order and preserves the shared
metric/bar grid in right-to-left locales. A one-lane fallback row must be no taller than the one-lane compact metric
row.

This is the only compact-mode exception to names plus drawable bars. It covers shipped status-only balance models and
all-unlimited services, plus dashboard- or notes-only providers and providers with no current usage data. Fallback text
truncates visually but uses the already-redacted full model text for accessibility. The row remains navigable to
provider details. A live transition into or out of these states follows the existing compatible-layout and
structural-rebuild rules.

### Accessibility

The compact row remains one actionable AppKit menu item. Use a structured accessibility hierarchy rather than
concatenating a sentence with hard-coded punctuation or English word order:

- The actionable row exposes the full provider name as its label and retains the existing open-provider-details action
  and hint.
- Each drawable lane is a non-actionable informational child, in model order, whose label is the full metric title.
  Its `UsageProgressBar` child keeps the existing localized `percentStyle.accessibilityLabel` (`Usage remaining` or
  `Usage used`) and existing accessibility value for the formatted percentage, quota-warning markers, and workday
  markers. This feature does not add new pace-announcement semantics.
- Hide the separate visual provider and metric `Text` nodes from accessibility so VoiceOver does not announce duplicate
  fragments. Visual truncation must not truncate accessibility strings.
- A no-bar row has one non-actionable fallback child. For a status fallback, its label and value are the full metric
  title and untruncated trimmed status respectively. For loading or generic fallback, its label is the full localized
  fallback. The actionable parent continues to carry the provider name and row action.
- Omitted account, plan, reset, storage, dashboard, credit, and cost content must not remain in hidden accessibility
  children.

Tests must inspect these label/value fields separately, including under an Arabic or Persian locale, and must reject a
single synthesized provider/metric/value phrase. This preserves localized semantics without adding a fourth format
key.

The three new localization keys are:

- `overview_compact_title`: **Compact Overview**
- `overview_compact_subtitle`: **Show provider names and usage bars in a space-saving layout.**
- `overview_compact_no_bars`: **No usage bars**

Use `overview_compact_no_bars` for both the visible generic fallback and its accessibility child label. Add all three
keys to all 23 complete locale catalogs and cover their presence with a focused localization-catalog test. The English
catalog uses the source copy above; the other 22 complete catalogs require non-empty reviewed translations rather than
copied English placeholders. English fallback is not the completion policy for these complete catalogs.

### Interaction

Compact and Detailed Overview preserve the same row-level interaction:

- the same `overviewRow-<provider>` identity;
- the same provider order and selected subset;
- the same click and keyboard activation behavior;
- the same usage, cost, storage, and provider-specific submenus;
- the same submenu indicator;
- the same `usesGPUSelection: true` hosting path;
- the same mouse-wheel and trackpad behavior;
- the same viewport restoration behavior; and
- the same Refresh, Settings, About, and Quit footer.

Selecting a compact row opens the existing detailed provider tab. Compact mode does not create a second compact
provider-detail surface. Compact has no embedded SwiftUI button, so its menu item must use
`containsInteractiveControls: false` while retaining `usesGPUSelection: true`.
Detailed keeps its existing `containsInteractiveControls` expression because its live error subtitle can expose a copy
button.

## Fit contract

Compact Overview should remain substantially shorter than Detailed without sacrificing readable text or bars. Use this
representative case for UI proof:

- macOS 27.0 in the project's Parallels UI environment;
- a 1280 × 720-point logical display at 2× scale, English locale, default text size, and light appearance;
- an actual resolved menu width of 310 points, not merely the 310-point baseline before standard-item measurement;
- Overview plus Codex, Claude, Cursor, OpenCode, Warp, and Gemini in the switcher, with switcher icons enabled;
- those same six providers selected for Overview and none excluded by the error-only filter;
- drawable-metric counts of `1, 1, 2, 2, 3, 3` in provider order, totaling twelve bars, using **Session**,
  **Weekly**, and **Code review** as needed at deterministic percentages;
- no update, agent-session, contextual-provider, storage, cost, credit, or debug rows; and
- the normal Refresh, Settings, About, and Quit footer.

For that fixture, the complete menu's intrinsic content height should be no more than 680 points. The canonical
attached clip-view height is at least 656 points; the expected Parallels result is roughly 660 points. A vertical scroll
range of up to 24 points is acceptable. If the attached viewport is shorter than 656 points, record it as an
environment mismatch and report its actual scroll range separately. Zero scrolling is preferred when the actual
display and menu attachment permit it, but the implementation must not shrink the revised header, metric text, or
progress bars merely to achieve zero.

The 680-point ceiling is a revised comfort-first design budget, not a previously measured result:

| Element | Count and per-item target | Budget |
| --- | --- | ---: |
| Overview plus six-provider switcher | two 36 pt rows + 4 pt spacing | 76 pt |
| Compact provider items | six header-plus-metrics items, twelve total lanes, including each host's 7 pt measurement inset | ≤432 pt aggregate |
| Refresh | `1 × 24 pt` | 24 pt |
| Native Settings, About, and Quit rows | provisional `3 × 22 pt` | 66 pt |
| Separators | provisional `7 × 9 pt` | 63 pt |
| AppKit measurement and pixel-rounding headroom | remainder | 19 pt |
| **Total ceiling** |  | **680 pt** |

The seven-separator fixture is one separator after the switcher, five between the six provider rows, and one before the
footer. If the built menu has a different separator topology, record the actual count and heights and rebalance the
budget explicitly rather than treating 63 points as fixed.

The switcher and Refresh values come from current source constants. Compact-item, native-item, and separator values
must be verified against the freshly built bundle because AppKit owns some of their geometry. A one-lane compact item
that exceeds 54 points, an additional lane increment that exceeds 20 points, or canonical compact items whose
aggregate exceeds 432 points is a failed design-budget assumption even if the complete menu happens to fit.

Available height is also measured rather than inferred solely from the display resolution. Runtime proof must record
the display's `visibleFrame.height` and the attached menu clip-view height; the expected Parallels fixture has roughly
660 points of usable vertical space. The revised 680-point ceiling intentionally accepts at most one metric-lane-sized
scroll increment in that environment in exchange for a dedicated provider header, larger labels, and larger bars.

This is an acceptance target, not a universal geometric guarantee. Metric counts are not globally bounded:
`extraRateWindows` and some provider responses can add additional windows. Accessibility text sizes and small displays
also reduce available space.

When fit and completeness conflict, preserve all drawable bars and allow AppKit scrolling. Do not silently cap metrics,
restore visible percentages, shrink the approved text or bar sizes, or introduce horizontal scrolling.

The PR's runtime proof must record the actual OS build and confirm every canonical parameter above. Record the resolved
menu width, display visible-frame height, intrinsic content height, attached clip-view height, per-item heights, and
vertical scroll range. A screenshot alone is supporting evidence, not the measurement.

## Technical design

### Settings and persistence

Add a display-only Boolean:

```swift
var mergedOverviewUsesCompactLayout: Bool
```

Persist it under a new stable `UserDefaults` key named `mergedOverviewUsesCompactLayout`. A missing key resolves to
`false`.

Plumbing:

- `SettingsStoreState.swift`: add the field near the merged-menu settings.
- `SettingsStore.swift`: load the default and pass it into `SettingsDefaultsState`.
- `SettingsStore+Defaults.swift`: add the synchronous state/UserDefaults accessor.
- `SettingsStore+MenuObservation.swift`: include it in `menuObservationToken`.
- `PreferencesMenuPane.swift`: add the toggle at the start of the Content section.

This preference must not increment `backgroundWorkSettingsRevision`, enter `CodexBarConfig`, change widget state, or
trigger provider fetching.

### Presentation seam

Keep `OverviewMenuCardRowView` as the outer row type so its callers and menu-item wiring do not fork. Give it an
explicit module-internal presentation style:

```swift
enum OverviewMenuRowStyle {
    case detailed
    case compact
}
```

`addOverviewRows` resolves the style from `mergedOverviewUsesCompactLayout` and passes it to the row. Detailed uses the
existing view composition unchanged. Compact uses a dedicated, small SwiftUI subview and the existing
`UsageProgressBar`. Resolve `storageFootprintText(for:)` only for Detailed; Compact omits the inline value and does not
need to read it. Continue constructing `makeOverviewRowSubmenu` in both styles because its storage fallback is
independent of the inline storage string.

Add a pure module-internal projection for compact metric lanes. It should make inclusion, order, labels, values, and
full accessibility source strings testable without constructing an `NSStatusBar` or live `NSMenu`.

Do not add a second provider model. The compact projection consumes `UsageMenuCardView.Model` and contains only the
fields necessary to render metric lanes or the deterministic no-bar fallback. It must consume the finished model after
`hidePersonalInfo` redaction rather than rebuilding any string from raw snapshots.

Keep responsibilities explicit:

- `OverviewMenuCardRowView` remains the outer style switch.
- Its Compact branch owns the fallback model, initial `layoutModel`, refresh-monitor resolution, and shared metric/bar
  columns.
- A projection-only `CompactOverviewRowContent` leaf receives only a compact projection and
  `CompactOverviewColumnLayout`; it has no refresh monitor, raw model, storage, or rich-card fields.

The projection also exposes an ordered **drawable-lane layout signature** derived from each included metric's
`Metric.id`, title, and percent style. Encode both ID and title through
`UsageMenuCardView.Model.heightFingerprintField(_:_:)`; the signature must never contain either raw string. It changes
when a lane is added, removed, reordered, replaced by a different ID, changes title or percent style, or changes
between bar and text-status presentation. Use it for compact compatibility and height-cache assertions; raw metric
count is not sufficient.

A no-bar projection exposes a separate **fallback layout signature**:

- `loading` includes the fallback kind;
- `status` includes the kind, selected `Metric.id`, and title shape; and
- `generic` includes the fallback kind.

Encode the selected status ID and title through `UsageMenuCardView.Model.heightFingerprintField(_:_:)`, which hashes
the value and records only its geometry-relevant shape rather than storing raw potentially personal text in a cache key.
Localization and fallback text content remain covered by the resolved model's existing height fingerprint, but are not
part of this layout signature: all fallback text is fixed to one `.body` line, and status text spans fixed columns,
so changing only that text cannot change measured height or shared-column allocation.

Implement the width rule through a module-internal `CompactOverviewColumnLayout`, computed once in `addOverviewRows`
from every monitor-resolved compact projection remaining after the existing error-only filter. Excluded providers must
not influence geometry. The layout contains the shared metric and bar widths plus spacing and chevron-gutter widths and
a stable signature. Provider headers span the content width and are not allocator inputs.

The shared-column signature contains only resolved numeric geometry, resolved text scale/font identity, layout
direction, and menu width. Metric titles are transient allocator inputs and must not be copied into that signature;
provider names and fallback copy are not allocator inputs at all.

The allocator receives the resolved menu width and the maximum ideal metric-label width across the whole rendered set.
Inputs include every drawable metric title and the selected title of each status fallback; loading and generic
fallbacks add no metric-title input. It clamps that maximum to 112 points, reserves the header-only chevron gutter and 12-point
metric-to-bar gap, and gives all remaining width to the bar subject to its 146-point floor. The allocator requires a
menu width of at least 310 points. Do not derive widths independently inside each hosted row: SwiftUI alignment guides
cannot cross the separate `NSMenuItem` hosts.

Obtain ideal widths before host construction through one injected, module-internal text-width measurer configured with
the exact compact metric font. Production may use the corresponding AppKit preferred font; pure allocator tests use a
deterministic stub. Do not create temporary SwiftUI hosts or query private subview geometry merely to measure strings.

Pass the same resolved `CompactOverviewColumnLayout` to every compact row. A DEBUG-only geometry probe may expose
resolved frames for the hosted-view integration test; do not inspect private SwiftUI hierarchy. The probe must prove
that metric and bar columns align across at least two separate hosted rows, that provider headers occupy their own row,
and that neither a submenu nor a no-submenu row overlaps the reserved chevron gutter.

### Live refresh

The compact branch must mirror Detailed Overview's `usesLiveSubtitle` gate, resolve one complete live model through
`MenuCardRefreshMonitor`, and derive the provider name, metrics, bar values, markers, tint, fallback, and accessibility
strings from that same result:

```swift
let liveModel = model.usesLiveSubtitle
    ? refreshMonitor?.model(for: model.provider, fallback: model) ?? model
    : model
```

Do not resolve a live subtitle separately or mix live and fallback metric state. The earlier Lite-row experiment
demonstrated that doing so can show a refreshed state beside stale bars.

At menu construction, `addOverviewRows` uses the same gate to obtain one `layoutModel` for each provider before it
builds compact projections, the shared column layout, and height fingerprints. The compact view receives the fallback
model, that initial `layoutModel`, and the shared columns. This mirrors the existing full-card model/layout-model seam:
compatible value changes can update in place, while the initial rendered or frozen shape controls measurement.

Menu construction and SwiftUI rendering are separate resolution transactions. Construction resolves at most once per
gated provider for measurement and fingerprints. Each later Compact body evaluation resolves at most once, immediately
projects that one result, and passes the projection to `CompactOverviewRowContent`. The first render may therefore make
a second resolver call after construction; that is intentional and keeps Observation dependencies current. Tests
assert one call within each transaction, not one call across the entire menu-build-plus-render lifecycle.

Existing compatible-layout rules remain authoritative. A structural metric-shape change may require the existing menu
rebuild path; Compact Overview should not weaken those guards. Compatible tracked updates cannot change metric ID,
title, percent style, or bar-versus-status shape. Any such change is rejected for in-place display and the subsequent
structural rebuild recomputes projections and shared columns for the entire rendered set. Provider-name or localization
changes likewise invalidate rendered content; a localized metric-title change also recomputes the shared metric/bar
columns rather than changing one row's widths in place.

Add a Compact-specific compatibility guard for the fallback layout signature. A change between loading, status, and
generic, or a change in the selected status metric ID/title, is structurally incompatible and forces the same
whole-menu rebuild so shared columns are recomputed. A trimmed status value may update in place when the selected
status metric and fallback kind stay the same; the fixed one-line span makes that a content-only change.

Keep model resolution separate from the pure projection. A focused resolver test should inject a monitor/resolver that
returns distinguishable values on successive calls, then prove one compact projection/update transaction resolves
once and produces one coherent row. Do not assert how often SwiftUI evaluates `body`.

Manual refresh deliberately inherits `MenuCardRefreshMonitor.model(for:fallback:)` freezing. While a provider has
active manual-refresh work, Compact keeps rendering the compatible frozen pre-refresh bars; it does not show the
subtitle monitor's synthetic `Refreshing…` text because Compact has no subtitle. Compute the initial lane signature,
no-bar fallback, shared-column inputs, and height fingerprint from the monitor-resolved or frozen `layoutModel`, not
from the fallback model. The metric-subset compatibility path can intentionally return a frozen model with more lanes
than the rebuilding fallback, and its measured height must win.

Every monitor result used here must come from the same finished `menuCardModel(for:)` path as the fallback and therefore
already include `hidePersonalInfo` redaction. Compact must not install a raw-snapshot resolver.

### Open-menu rebuilding

Adding the setting to `menuObservationToken` invalidates cached menus, but it is not sufficient for a menu that is
already open.

Track the last observed compact-layout value beside `lastMergeIcons`, `lastSwitcherShowsIcons`, and
`lastObservedUsageBarsShowUsed` in `StatusItemController`. A change must make
`shouldRefreshOpenMenusForProviderSwitcher()` return true so the open merged menu receives a safe structural rebuild.

### Height cache

Detailed and compact rows must not share a measured-height fingerprint. Use a style-specific section or include the
style as an explicit fingerprint field, for example:

```swift
section: style == .compact ? "overviewCompact" : "overviewDetailed"
```

Renaming Detailed's current section from `"overview"` to `"overviewDetailed"` changes cache identity only; it is not a
visual or interaction change. Detailed mode keeps storage text in its fingerprint. Compact mode omits storage from both
its visible content and height fingerprint. This prevents a cached detailed height from leaving blank space around
compact content after the toggle changes.

For Compact, use `UsageMenuCardView.Model.heightFingerprint` on the resolved `layoutModel`, which already includes
metric shape and localization. Detailed continues using its current model-plus-storage fingerprint under the renamed
section. The existing cache key already includes menu width and resolved text scale. Add the style, compact
drawable-lane or fallback-layout signature, and shared-column-layout signature as explicit Compact fingerprint inputs.
Although GPU Overview hosts are built fresh rather than recycled, explicit height-cache entries survive menu
invalidation and remain provider-scoped; a peer provider can therefore change shared columns without changing this
provider's base model.

Test peer-selection column changes, bar ↔ status, one-lane, two-lane, frozen-subset layout, and
Detailed → Compact → Detailed keys. Re-entering Detailed may safely reuse its original detailed height. Keep the
existing model compatibility rule that treats `statusText` nilness as a structural difference.

### Privacy and provider isolation

Compact mode is more private by construction because it removes inline account and plan identity. `hidePersonalInfo`
still applies: compact projection starts from the already-redacted `UsageMenuCardView.Model`, so embedded emails in
metric titles or status fallback text remain protected even when the setting causes no obvious visual difference. No
provider may borrow identity, plan, tint, metrics, or fallback text from a different provider.

No new logging or telemetry is needed.

## Edge cases

| Case | Required behavior |
| --- | --- |
| More than six providers enabled | Keep the existing configured Overview subset and six-provider cap |
| Provider has one drawable metric | Show one provider header followed by one metric lane |
| Provider has several drawable metrics | Show one provider header followed by every drawable lane in model order |
| Some metrics have `statusText` instead of a bar | Omit those metrics while rendering every drawable metric |
| Provider is loading and has no drawable metrics | Show the provider header followed by the localized generic loading fallback |
| Provider has only text-status metrics | Show the provider header followed by the first non-empty status metric in model order |
| Provider has dashboard, notes, credits, cost, or no data but no drawable/status metric | Show the provider header followed by `overview_compact_no_bars` |
| Provider is error-only at build time | Apply the existing exclusion before the compact projection |
| Live values change without metric-shape change | Update all compact bar data from one monitor-resolved model |
| Live metric shape changes | Follow existing compatible-layout/rebuild behavior |
| Manual refresh is active | Keep compatible frozen bars; do not add a compact `Refreshing…` subtitle |
| Long or right-to-left localized names | Routine truncation is allowed at 310 points; preserve the shared metric/bar columns, 146-point bar, and full accessibility text |
| Used/remaining preference changes | Update bar fill and preserve full `percentStyle` value and used/remaining semantics in accessibility; do not add visible numeric text |
| Pace or marker settings change | Preserve existing bar rendering and menu invalidation behavior |
| Storage footprints enabled | Omit inline storage; retain the existing storage submenu fallback |
| A peer provider or Overview selection changes | Recompute one shared column layout and include its signature in compact height keys |
| Compact toggled while menu is open | Structurally rebuild the open Overview and use the correct cached height |
| Merge Icons disabled | Disable the control but retain its stored value |
| Accessibility or unusual metric count causes overflow | Preserve all bars and allow native menu scrolling |
| Refresh completes during a style rebuild | Main-actor rebuild rules keep updates on the current host and cache key |

## Files expected to change

Keep the implementation small and localized:

- `Sources/CodexBar/SettingsStoreState.swift`
- `Sources/CodexBar/SettingsStore.swift`
- `Sources/CodexBar/SettingsStore+Defaults.swift`
- `Sources/CodexBar/SettingsStore+MenuObservation.swift`
- `Sources/CodexBar/PreferencesMenuBarPane.swift` to remove the toggle from Combined Icon
- `Sources/CodexBar/PreferencesMenuPane.swift` to add the toggle to Content
- `Sources/CodexBar/StatusItemController.swift`
- `Sources/CodexBar/StatusItemController+Menu.swift`
- `Sources/CodexBar/StatusItemController+MenuWidthCache.swift` to update the Compact width contribution if required
- `Sources/CodexBar/StatusItemController+MenuTypes.swift`
- an optional focused compact projection/layout file under `Sources/CodexBar`
- `Sources/CodexBar/Resources/*.lproj/Localizable.strings`
- focused tests under `Tests/CodexBarTests`
- `docs/ui.md` with the revised behavior

Do not edit `CHANGELOG.md` as part of feature implementation.

## Test plan

### Pure compact projection

Add `Tests/CodexBarTests/OverviewMenuCardRowViewTests.swift` and cover:

- every drawable metric is retained in model order;
- text-only metrics are omitted;
- loading, first-status-metric, and generic no-bars fallback precedence is deterministic;
- status-only Mistral/DeepSeek-style, all-unlimited MiniMax-style, and dashboard-only OpenAI-style fixtures produce an
  informative single-line fallback rather than a bare name;
- whitespace-only status text is skipped, status fallback uses separate metric/status columns without hard-coded
  punctuation, and loading is selected exactly by `subtitleStyle == .loading`;
- percent value/style, tint, pace, quota markers, and workday markers pass through unchanged;
- a source model populated with sentinel account, plan, subtitle, reset, detail, dashboard, notes, cost, and credit
  strings, plus a detailed-row-only storage sentinel, produces compact projection/rendered accessibility output
  containing none of those sentinels except an explicitly selected, already-redacted status fallback;
- no visible numeric percentage is projected or rendered while the bar retains the complete percentage and
  used/remaining accessibility meaning; and
- full provider and metric strings survive projection unchanged.

Cover fallback, 1-, 2-, 3-, 6-, and 12-lane projections. Assert there are no reserved blank lanes, no two-lane cap,
and no provider-name repetition; every drawable metric must survive in model order.

Assert drawable-lane signature changes independently for ID-only replacement, reordering, title change,
`percentStyle` change, insertion/removal, and bar ↔ status change. Also assert each no-bar fallback kind includes the
specified layout fields without embedding raw IDs, provider names, metric titles, localized copy, or status values in
the key. Assert the shared-column signature likewise contains geometry only. Verify a status-value-only change keeps
the fallback layout signature stable while updating visible and accessible content.

Make `CompactOverviewRowContent` accept only the compact projection and shared columns; absence of refresh, model,
storage, and unrelated rich-card fields from that leaf type is a compile-time and review invariant. Test live resolution
separately with an injected spy resolver. Assert that `usesLiveSubtitle == false` performs no resolution. For a live
model, return different sentinel values on successive calls, then assert separately that construction and one
projection/update transaction each perform at most one resolution and that each transaction produces one coherent
provider/tint/metric result.

Add a manual-refresh fixture in which the monitor's compatible frozen model has more lanes than the rebuilding fallback;
measurement and fingerprinting must use the frozen lane shape, frozen values remain visibly projected, and Compact
contains no synthetic `Refreshing…` text. Run the live resolver with `hidePersonalInfo` enabled and assert the monitor
projection contains only already-redacted titles and fallback strings.

Table-test the pure column allocator at the 310-point production minimum and at wider widths with short, long, German,
Polish, Persian or Arabic right-to-left, and Traditional Chinese ideal widths. Reject an input below 310. At 310 and
default text size, assert the exact 40-point outer padding, 112-point metric cap, 12-point metric-to-bar gap, 12-point
header chevron gutter, and 146-point bar floor. Assert provider-title widths do not affect the shared layout. At wider widths,
assert all surplus goes to the shared bar. At a larger text scale, assert width/text-scale cache keys differ while the
112-point metric cap and 146-point bar floor remain intact.

Changing a peer provider must change the shared layout only when its metric titles change a capped selected-set maximum
or another resolved column width. Provider-name-only changes must not change the shared layout. Cover uncapped metric
width change, above-cap no-op, provider removal, and the error-only filter so an excluded provider never influences
columns.

Use the DEBUG geometry probe against at least two separately hosted compact rows to prove each provider header occupies
its own line and their metric and bar frames align. Cover logical leading/trailing behavior, submenu and no-submenu
rows, header-aligned chevrons, and assert no content enters the chevron gutter. Separately assert visual labels stay
single-line, no visible numeric percentage view exists, drawable lanes are non-actionable accessibility children in
model order without duplicate visual text nodes, and a no-bar row exposes the specified parent label plus
fallback-child label/value fields. The accessibility representation must retain full provider and metric strings,
used/remaining semantics, percentage, fallback, and existing marker semantics without a synthesized English-order
phrase. Exercise the hierarchy under an Arabic or Persian locale. Keep pixel screenshots out of CI.

### Settings and observation

Extend `SettingsStoreTests.swift` to prove:

- the default is detailed (`false`);
- compact mode round-trips through a second `SettingsStore` using the same suite;
- changing it fires the menu observation callback; and
- changing it leaves background-work, provider-fetch scheduling, config, cost/widget display, and provider-detail
  revisions unchanged.

Extend localization-catalog coverage to require `overview_compact_title`, `overview_compact_subtitle`, and
`overview_compact_no_bars` in all 23 complete catalogs with non-empty values. PR review must confirm the 22 non-English
catalog values are translations rather than copied English placeholders.

Extend `PreferencesPaneSmokeTests.swift` to construct the Menu pane with both values. Cover the toggle binding, its
placement in the Content section rather than the Menu Bar pane, disabled state while Merge Icons is off, and value
retention across Merge Icons off → on. Use runtime visual proof for exact row placement rather than brittle SwiftUI
tree introspection.

### Menu integration

Cover both styles while preserving existing assertions:

- same row count, provider order, and `overviewRow-` identities;
- same click and keyboard actions;
- same detail submenus and storage fallback;
- same GPU-selection host and scroll targeting;
- Compact passes `containsInteractiveControls: false`, while Detailed retains its existing expression;
- Compact skips `storageFootprintText(for:)` without losing the independently constructed storage submenu fallback;
- a programmatic setting change while the menu is tracking replaces detailed content with compact content in both
  directions;
- a refresh delivered around that rebuild updates only the current host/model/cache key;
- detailed and compact height fingerprints cannot collide, while peer metric/bar geometry, fallback, bar ↔ status, frozen-subset,
  and one- versus two-lane compact layouts also differ; and
- a fallback-kind or selected-status-metric change causes a whole-menu rebuild, while a value-only change for the same
  selected status metric updates in place; and
- a representative compact row measures shorter than the unchanged detailed branch for the same fixture.

Also cover zero selected providers, more than six enabled providers, mixed drawable/text-only metrics, bar ↔ status
shape changes, and an overflow fixture that preserves every lane. Preserve existing viewport behavior; this feature
does not add a new pixel- or provider-anchor policy for a setting normally changed while the menu is closed.

Prefer pure projection and state seams. Keep AppKit coverage focused on the wiring that cannot be proven otherwise.

### Validation commands

During implementation, run the fastest focused checks first:

```bash
swift test --filter OverviewMenuCardRowViewTests
swift test --filter SettingsStoreTests
swift test --filter PreferencesPaneSmokeTests
swift test --filter CompactOverviewMenuIntegrationTests
swift test --filter StatusMenuOverviewScrollTests
swift test --filter "StatusMenuTests.*overview"
make check
```

Name the new integration suite `CompactOverviewMenuIntegrationTests`. Validation notes must record the tests selected
and executed so a filter that accidentally matches zero tests cannot pass unnoticed.

Before submitting a PR, run the repository's full `make test` suite. The focused tests must use synthetic snapshots,
stub stores, and `KeychainNoUIQuery`-safe paths; do not run live provider or browser-cookie probes.

### Runtime proof

Because the product goal is spatial and an `NSMenuTrackingSession` cannot be fully proven by unit tests, validate a
freshly built bundle in the project's supported macOS UI environment. Use an existing local synthetic/debug injection
if one is available. If not, keep the fixture in a test harness or DEBUG-only launch path that cannot ship as a
production provider or fetch path and that disables real probes.

Add or reuse a DEBUG/test-only numeric measurement seam that reports:

- resolved menu width and display visible-frame height;
- full menu intrinsic content height;
- attached clip-view height;
- vertical scroll range, calculated as `max(0, documentHeight - viewportHeight)`;
- ordered item identifiers and measured heights; and
- the ordered provider/lane IDs present in the menu.

The canonical fit fixture passes when resolved width is exactly 310 points, each provider header occupies its own line,
one-lane items are shorter than two-lane items, every one-lane item is at most 54 points tall, each additional lane adds
at most 20 points, the six compact items total at most 432 points, intrinsic height is at most 680 points, vertical
scroll range is at most 24 points, and all twelve expected lane IDs are present. The overflow fixture passes when every
expected lane ID is present and vertical scroll range exceeds the canonical allowance.

The canonical harness must configure the production width inputs and then observe the attached menu's resolved width;
it must not force a DEBUG-only 310-point frame after layout. If AppKit or a standard item widens the canonical fixture,
the exact-width assertion fails and the fixture, width calculation, or 310-point contract must be corrected.

1. Configure the exact canonical fixture from the Fit contract using local synthetic data.
2. Record the actual OS build, resolved width, visible-frame height, per-item heights, and all other measured fit values
   required by the contract.
3. Capture Detailed and Compact Overview at the same display size and text settings.
4. Prove Compact shows all twelve bars plus the six dedicated provider headers, switcher, and standard footer, stays
   within 680 points, and has at most 24 points of vertical scroll range.
5. Use an in-process test hook to change the preference while the menu is tracking and verify both style directions,
   current-host refresh, and correct row heights.
6. Run a response-sized overflow fixture with enough additional lanes to force scrolling; prove every lane remains and
   native scrolling works.
7. Click and keyboard-activate rows, open representative usage/cost/storage submenus, and exercise trackpad and wheel
   navigation.
8. Repeat in light and dark appearance and with personal-info hiding enabled.
9. Capture redacted screenshots or a short recording for the PR.

Use `./Scripts/compile_and_run.sh` only for this final bundle-level UI validation, after focused tests and
`make check` pass.

## Implementation plan

1. Add the default-off persisted Boolean, menu observation, and Menu-pane toggle.
2. Add the pure compact-row projection and focused tests for inclusion, order, no-bar fallback, semantics, and full
   source strings.
3. Add the shared metric/bar column allocator, fixed chevron gutter, minimum-width budget tests, and hosted geometry
   probe.
4. Add the compact SwiftUI row using the existing progress renderer and one gated monitor-resolved live model.
5. Pass the selected row style, resolved layout models, and shared columns through `addOverviewRows`; preserve row
   identity, set Compact's embedded-control flag false, and skip only Compact's inline storage lookup.
6. Add open-menu structural refresh tracking and style-, rendered-shape-, and shared-column-specific height
   fingerprints.
7. Extend Overview interaction, frozen-refresh, submenu, settings, all-catalog localization, accessibility, and overflow
   tests.
8. Run focused checks, `make check`, then the freshly built bundle UI proof with per-item measurements.
9. Update `docs/ui.md`; run `make test` immediately before PR submission.

## Acceptance criteria

The feature is ready when:

- Detailed Overview remains the default, uses the existing detailed view composition, and has no intentional visual or
  interaction change.
- The setting persists, appears in Preferences → Menu → Content rather than the Menu Bar pane, is disabled without
  clearing while Merge Icons is off, and is contextual to the merged Overview UI.
- Changing the setting has no provider-fetch, background-work, config, widget, account, or provider-detail side
  effects.
- Compact Overview shows every provider remaining after the existing error-only filter and every drawable metric bar
  for those providers in model order.
- Compact mode contains none of the excluded rich-card content.
- Loading, status-only, and other no-bar providers use the specified visible, accessible fallback; existing error-only
  filtering remains unchanged.
- In the canonical English/default-text-size fixture at a resolved width of exactly 310 points, every provider has one
  dedicated header row and every item shares one metric/bar column layout. Labels truncate within their caps, bars
  remain at least 146 points wide and eight points tall, no numeric percentage is visible, the chevron gutter remains
  unobstructed, and accessibility keeps the full strings and percentage/marker semantics. Larger resolved text may
  increase item height but keeps the fixed metric cap and bar floor.
- The canonical mixed-cardinality `1, 1, 2, 2, 3, 3` six-provider/twelve-bar fixture has one-lane items no taller than
  54 points, additional lanes adding at most 20 points each, compact items totaling at most 432 points, a complete menu
  within 680 points, at most 24 points of vertical scroll range, all twelve expected lane IDs, and redacted visual proof
  plus recorded per-item measurements.
- Every drawable bar is retained for 0/1/2/3+ and response-sized metric sets. When completeness and fit conflict,
  Compact uses native vertical scrolling rather than truncation, collapsing, ranking, or a per-provider bar cap.
- Live refresh mirrors the existing gate, never mixes stale and current row state, and preserves compatible frozen bars
  during manual refresh.
- A setting change during menu tracking rebuilds in both directions, survives a concurrent refresh, and cannot reuse a
  detailed-row, wrong-lane-count, wrong-fallback, frozen-shape, or peer-metric-geometry height.
- Existing click, keyboard, submenu, GPU highlight, scroll, viewport, provider-order, and selection behavior remains
  green; Compact alone disables embedded-control hit testing.
- `overview_compact_title`, `overview_compact_subtitle`, and `overview_compact_no_bars` are present in all 23 complete
  locale catalogs, with reviewed non-English translations rather than English placeholders.
- Focused tests, `make check`, and the pre-PR full suite pass without Keychain prompts.

## Approved owner decisions

| Decision | Recommendation | Alternative and cost |
| --- | --- | --- |
| Default layout | Detailed | Defaulting compact changes every existing installation's menu |
| Setting shape | Boolean toggle | An enum/picker adds ceremony without a third approved layout |
| Provider scope | Existing selected six | “Every enabled provider” requires a separate selection-model redesign |
| Visible bar text | Short metric label only; the bar retains percentage and used/remaining semantics in accessibility | A visible percentage reduces bar width and made the first implementation feel too small |
| Metric completeness | Keep every drawable metric | Capping bars contradicts the request and hides quota windows |
| Overflow policy | Allow native scrolling in exceptional cases | Dropping data or shrinking below platform norms is misleading |
| Provider presentation | One dedicated header row inside each actionable provider item, with metric lanes below | A provider column competes with metric and bar width and made the item feel cramped |
| Cross-row geometry | One shared selected-set metric/bar layout with fixed cap and chevron gutter | Per-host ideal sizing cannot align independent `NSMenuItem` roots |
| Non-bar providers | One muted status/loading/no-bars fallback below the provider header | A bare provider name reads as an unfinished row; hiding it changes the configured subset |

These approved decisions make this document the bounded implementation contract.
