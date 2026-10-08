---
summary: "Notch hover overlay: settings pane, column layout, tile order, hotkey modes, and the four usage bars per provider."
read_when:
  - Changing the notch overlay panel, its columns, its hotkey, or its hover timing
  - Adding or reordering the usage bars the overlay renders
---

# Notch usage summary

Opt-in overlay that expands a usage dashboard under the camera notch of a built-in display.
Everything is configured in its own settings page: **Settings → Notch**.

Synthetic provider tiles in brand and monochrome styles:

![Brand provider tiles with shared visibility and reset labels](https://github.com/user-attachments/assets/bd35432c-d8c3-4f35-af2b-476adb08e843)

![Monochrome provider tiles](https://github.com/user-attachments/assets/43563b95-fc88-45cd-916d-8807ca3723dd)

## Settings
- `notchUsageSummaryEnabled` — off by default; no panel exists until it is on.
- `notchColumnCount` (1–4, default 1) — how many columns the tiles flow into. Width is never
  configured; the panel measures its own content.
- `notchMatchesRowHeights` (default on) — off, each column packs independently, so a short tile
  sits directly under a tall one. On, every tile in a grid row is as tall as that row's tallest.
- `notchProvidersMaxHeight` (100–1600, default 500) — ceiling for the provider grid; tiles past it
  scroll while the session band stays put.
- `notchSessionsMaxHeight` (100–1600, default 200) — ceiling for the session band; a longer list
  scrolls inside the band.
- `notchItemOrder` — provider instance IDs in display order. Keys absent from the list keep their
  natural position, so a newly enabled provider appears without the user re-sorting anything.
- `notchHiddenProviders` — providers are **opt-out**: a newly enabled provider joins the overlay
  without the user revisiting the pane.
- `notchShowsAgentSessions` — shows the agent-session list; requires Agent Sessions (Menu pane).
  The overlay reads `StatusItemController`'s `AgentSessionsStore` rather than running a second
  scanner, wired in `AppDelegate.ensureStatusController()`.
- `notchSessionsPlacement` (`above`/`below`, default `below`) — which side of the grid the band sits
  on. The list is always a full-width band with its own height budget, never a tile in the grid, so
  it takes no slot in `notchItemOrder`.
- `KeyboardShortcuts_showNotchOverlay` + `notchHotkeyMode` — optional shortcut and whether it
  toggles or only shows while held.

## Layout
- Tiles fill the grid in list order, left to right then down: item `i` sits at column
  `i % columnCount`, row `i / columnCount`. `columns()` and `rows()` slice that one placement two
  ways — `columns()` feeds the packed layout, `rows()` feeds the matched-height `Grid`, so both
  modes put the same tile in the same cell and only row heights differ.
- `NotchUsageOverlayContent` renders tiles at their natural size, each capped at
  `maximumTileWidth` (320pt) so one long provider message cannot stretch the whole panel.
- The two sections are budgeted independently. The band sits outside the grid's scroll view, so the
  session list is always visible: the grid scrolls at `notchProvidersMaxHeight`, and the band
  scrolls inside itself at `notchSessionsMaxHeight`.
- When the display clamps the combined height, both viewports shrink proportionally and remain
  independently scrollable. Neither section can consume the other’s entire allocation.
- Each section reports the height its content wants from *inside* its own scroll view
  (`NotchGridHeightKey`, `NotchBandHeightKey`), where nothing clamps it, and
  `NotchUsageOverlayController.expandedFrame` sums those two reports — each capped by its own
  ceiling — plus the stack's spacing and padding. Measuring a separate copy instead drifts from what
  SwiftUI lays out, which showed up as content stuck behind a scroll no matter how high the ceiling
  was raised. The total is still bounded by 90% of the screen height and the screen width less a
  margin. The interactive content frame is anchored below the camera housing's bottom edge, outside
  both auxiliary menu-bar areas, including when the display has a nonzero origin.
- The frame is re-measured while the panel is open: `applyExpandedFrame` wraps the measurement in
  `withObservationTracking`, so a snapshot landing after the panel opened resizes it. Without that
  the panel keeps its opening size and late-arriving bars are stuck behind a scroll.
- The panel's hosting view sets `sizingOptions = []`. Without it the hosting view installs its
  content's ideal size as window constraints and a long provider list grows the panel off-screen.

## Hover and hotkey
- Two borderless, non-activating `NSPanel` windows share one controller. A camera-housing-sized
  tracking trigger stays in the notch; the wider interactive content window starts below the menu
  strip and is hidden while collapsed. Neither becomes key or main. Expanding never widens the
  notch trigger or covers neighboring menu extras.
- Hover is detected by an `NSTrackingArea` (`.activeAlways`, `.inVisibleRect`,
  `.mouseEnteredAndExited`) on the hosting view — no global event monitor, so no Accessibility
  permission.
- Entering either surface starts a 0.35s dwell before expansion. Leaving both starts a 0.4s grace
  period, cancelled by re-entry. Crossing between the trigger and content preserves hover ownership.
  Collapse immediately disables content mouse handling, then hides that window after the animation;
  its hide task is separate from hover grace so a re-entry cannot leave an invisible click target.
- `NotchHotkeyState` is the pure decision table for the shortcut: toggle flips on each press and
  survives key release; hold expands on press and collapses on release unless the pointer is inside,
  in which case hover takes over. While the shortcut holds the panel, losing the pointer cannot
  collapse it.
- `NotchUsageOverlayController` observes the setting and
  `NSApplication.didChangeScreenParametersNotification`; turning the setting off or losing the
  notched screen cancels all pending transitions and tears both windows down without a relaunch.

## Provider presentation
`NotchUsageOverlayModel.make(store:settings:agentSessions:)` walks
`UsageStore.enabledProvidersForDisplay()`, including enabled user-plugin instances.
First-party tiles use the shared menu-card input and presentation model, so provider-owned labels,
quota selection, hidden usage items, reset display style, optional usage, and error redaction follow
the menu. Each tile shows at most four metrics. When there is no extra metric, its spare slot can
show the shared provider-cost presentation, including monthly credits from the same account-scoped
input. Text-only balances remain text instead of inventing a quota bar.

Provider logos use the shared icon resources. **Icon and Percent** mode uses the curated brand
artwork; the other menu-bar icon modes use monochrome marks. Provider accent colors and the
**Usage bars fill** preference continue to control the quota bars. Collapsed views do not rebuild
provider rows as snapshots arrive.

User-provider plugins retain the generic primary, secondary, tertiary, and first-known-extra-window
projection, falling back to capped provider spend. A plugin with no renderable bar shows its error
or “No usage fetched yet”.

## Headless verification

`NotchGeometryTests`, `NotchHoverStateTests`, `NotchHotkeyStateTests`, and
`NotchUsageSettingsTests` cover geometry, hover ownership, settings, and lifecycle behavior.
Shortcut registration is injected in lifecycle tests; no real hotkey or display window is needed.

Render synthetic overlay and settings images without launching the app:

```bash
source Scripts/test_environment.sh
CODEXBAR_NOTCH_RENDER_DIR=/tmp/notch-proof swift test --build-system native --jobs 4 -Xswiftc -gnone --filter NotchOverlayRenderTests
```

These renders cover presentation, not native event delivery. Before merging, verify on a notched
Mac that neighboring menu extras remain clickable, crossing between trigger and content preserves
hover, and shortcut, scrolling, disablement, and shutdown behave correctly.

See also: `docs/providers.md`.
