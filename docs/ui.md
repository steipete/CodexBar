---
summary: "Menu bar UI, icon rendering, and menu layout details."
read_when:
  - Changing menu layout, icon rendering, or UI copy
  - Updating menu card or provider-specific UI
---

# UI & icon

## Settings
- Usage & Spend heatmap tooltips prefer the space above the hovered cell and stay within the grid, falling below when needed. On narrow grids they compact vertically and may overlap cells; keyboard selection remains available in the daily grid.
- Both the application menu and status menu open About in the Settings window. An existing Settings window is reused
  and switches to the About pane.

## Menu bar
- LSUIElement app: no Dock icon; status item uses custom NSImage.
- Cached status menus and previously opened submenus follow macOS appearance changes before reopening, preserving the effective Light/Dark and accessibility appearance.
- Merge Icons toggle combines providers into one status item with a switcher.
- With the automatic metric selected, switcher progress honors a provider's exhausted-quota selection before
  showing normal weekly progress. Healthy allowances, explicit metric choices, and separate provider pools
  retain their existing selection rules.
- Provider status items use stable autosave names and are reused across provider toggles so macOS can preserve icon
  positions.
- When Overview has selected providers, the switcher includes an Overview tab that renders up to 6 provider rows.
- Overview row order follows provider order; selecting a row jumps to that provider detail card.
- Menu-card wrappers use standard non-vibrant view behavior so white GPU-tinted Overview content remains visible on macOS 15. Overview selection stays outside the SwiftUI graph, with native submenu click and drag tracking retained.
- The global open-menu keyboard shortcut toggles the currently tracked menu closed before opening a new one.
- Display → Menu Bar → Layout provides presets plus a token editor. Tokens can be clicked to append, dragged from the
  palette, reordered between one or two lines, dragged out, or removed with Delete. Layouts can be global or overridden
  per provider. Manual edits select the Custom preset.
- Time tokens offer Session and Weekly variants of Resets in and Reset at, including in conditional branches.
  The original unqualified reset tokens continue to follow the automatic window. A selected window that is
  unavailable displays a dash rather than substituting another window. Saved layouts use V3 keys alongside a
  v0.56.8-readable V2 projection, which omits the new tokens and conditional rules that use them while preserving
  existing conditional placements, direct lane selections, and other providers' overrides. Re-upgrading restores
  the full layout unless an older release changed its saved projection. The oldest-format projection is also retained.
- All providers previews the default layout and lists enabled providers with saved overrides, even when an override
  currently matches the default. Each “Use all-providers layout” action removes only that provider's override;
  global edits preserve overrides, and disabled providers are left untouched. Before a default is first saved,
  editing still starts from the representative provider's effective layout.
- Small/Regular controls the token font scale. Tight/Regular controls status-item padding. Compact stacked uses two
  tightly spaced lines sized to fit the menu bar.

### Layout tokens

| Group | Tokens | Behavior |
| --- | --- | --- |
| Identity | Icon, Provider name, Account | Provider-scoped branding and identity |
| Usage | Session %, Weekly %, Scoped weekly %, Auto %, Usage bar | Window percentage or a compact three-glyph usage bar |
| Usage | Session pace, Weekly pace, Auto pace | Signed pace delta for that window |
| Time | Resets in, Reset at (automatic, Session, Weekly), Runs out | Selected-window relative reset, absolute reset, or pace estimate |
| Money | Balance, Cost today, Cost 30d | OpenRouter credit balance, or local cost estimate for the selected period |
| Structure | Separator dot, Space, Line break | Spacing and optional two-line composition |

The pace tokens render the same delta the menu card shows as "in deficit"/"in reserve", in the compact signed form the
pre-0.45 **Both** display mode used: `+11%` means usage runs that far ahead of the sustainable rate, `-8%` that far
behind it, `0%` on pace. Each pace token reads its own window, so `Weekly pace` never borrows the session delta — unlike
`Runs out`, which always estimates from the weekly (or automatic) lane. A pace token renders an en dash while pace is
unavailable, including the first 3% of a window. The weekly menu-bar pace token may appear after 1% of its weekly
window has elapsed; session, automatic, and Runs out tokens keep the 3% threshold. See [Pace tracking](#pace-tracking).

Enable **Color Pace Indicator** under **Menu Bar → Icon** to show usage behind pace (reserve) in green and usage ahead
of pace (risk of running out early) in red. The option defaults off, applies to all three pace tokens and the layout
preview, and keeps the signed percentages. Zero and unavailable pace stay neutral; stale pace colors are dimmed unless high-contrast rendering is active.
It colors **Session pace**, **Weekly pace**, and **Auto pace** in the layout editor. Enabling it does not add tokens,
rewrite stored layouts, or migrate legacy display modes. Existing installs stay monochrome until the option is enabled.

Balance is available only for OpenRouter and renders the same remaining-credit value shown in its menu card. Auto %
uses the same provider-aware automatic-window resolution as the legacy menu bar metric setting. For balance-only
providers, Auto % shows the available money, points, or API spend instead of inventing a quota percentage. Both the
status item and editor preview preserve real quota percentages when a usable limit exists. When a reset token
falls back to that same balance, a visible Auto % token shows it once; reset-only layouts keep the balance fallback. If a snapshot
does not provide a token's data, that token renders an en dash while its siblings remain visible. Existing installs
derive their first layout from the prior style, display mode, metric, and reset settings; those legacy keys remain
untouched for downgrade safety, while a saved token layout takes precedence.

Scoped weekly % selects the most constrained active model-specific weekly carve-out. The editor keeps a stable,
model-generic token label while the rendered menu-bar prefix and accessibility label follow the active model title.

## Icon rendering
- 18×18 template image.
- Bar windows are provider/style-specific primary and secondary windows.
- Fill represents percent remaining by default; “Show usage as used” flips to percent used.
- Renderer/critter icons dim when last refresh failed and can render incident indicators; brand display mode uses provider branding plus title text.
- Loading animation runs at a bounded frame rate and has a hard continuous-duration ceiling so provider hangs cannot keep
  the menu bar redrawing forever.
- Ordinary, fresh single-line text-only token layouts use cached template images so AppKit can reuse them across
  status-item redraws while retaining native highlighting and display-scale handling. The existing bounded renderer
  cache includes the content and appearance; memory-pressure cleanup clears it. Stale data, high-contrast mode,
  provider icons, attachments, colored glyphs such as emoji, and multiline text keep their attributed-title rendering. Critter and bar styles
  keep their existing renderers.

## Menu card
- Provider-specific rows with resets (countdown by default; optional absolute clock display). Primary, secondary,
  tertiary, and extra windows render when the provider snapshot has data for them.
- Manual refresh updates the open card subtitle and persistent Refresh-row spinner in place. Repeated clicks share the
  active request, and the existing row geometry remains fixed through success or failure.
- Live pace and metric detail text use the full row width. Updates that exceed the space reserved when the menu opened
  show a trailing ellipsis; reopening the menu measures the updated text again.
- Codex credits can add a separate “Buy Credits…” menu action.
- Claude capped Extra Usage follows the used/remaining fill preference; spending amounts and “% used” copy stay unchanged.
- Codex OpenAI web extras: code review remaining and usage breakdown render when dashboard data is attached.
- Token accounts: optional account switcher bar or stacked account cards (up to 6) when multiple manual tokens exist.
- At four or more accounts, compact stacked rows show each constrained quota (up to two) with its own reset time.
  Healthy rows show the quota with the least remaining capacity. Percentages and resets stay scoped to the same
  account and window; a sooner reset on another quota does not replace the limiting quota's reset.
- Compact rows use the existing Reset times countdown/absolute preference and shared formatter. Missing reset data
  leaves the quota label and percentage visible without inventing a time. Long localized details wrap, and VoiceOver
  includes the reset. Click a row to expand its full card; segmented cards keep their existing reset presentation.
- Primary compact quotas honor the provider's menu-card reset policy: balance descriptions are not presented as
  reset times, suppressed resets stay hidden, and provider-owned display text does not gain a reset prefix.
- Token/cost, credit-usage breakdown, credits-history, and plan-history chart date labels retain their full text width
  in narrow menus. Credits and plan history reserve plot-edge space to avoid clipping; token/cost and usage-breakdown
  charts retain their automatic scale range. Shared styling uses a
  bar-centered anchor, and each chart retains its own date formatting, domain, and tick-selection behavior.
- Provider storage usage is opt-in from Advanced settings. When enabled, overview rows and provider detail cards can show
  local provider-owned storage totals, with a submenu for path breakdowns and copyable paths.

## Pace tracking

Pace compares your actual usage against the expected consumption rate for the current window. Most providers use an even-consumption budget; Codex can use historical pace data when historical tracking is available.

The **Work days** setting selects the weekly pace model. **Automatic** uses Codex historical pace when enough data is available. Historical daily credits follow local calendar-day boundaries, including midnight daylight-saving transitions. Selecting 4, 5, or 7 days uses that explicit schedule for pace and ETA instead; CodexBar continues collecting history in the background, but does not use historical predictions until the setting returns to Automatic.

- **On pace** – usage matches the expected rate.
- **X% in deficit** – you're consuming faster than the even rate; at this pace you'll run out before the window resets.
- **X% in reserve** – you're consuming slower than the even rate; you have headroom to spare.

When usage is in deficit, the right-hand label shows an estimated "Runs out in …" countdown. When usage will last until the reset, it shows "Lasts until reset".

Pace is calculated for any provider window with enough reset timing data and is hidden when less than 3% of the
window has elapsed. The weekly menu-bar pace token is the one exception: it may appear after 1% of the weekly
window has elapsed, including when Codex historical tracking predicts less than 1% usage. Session, automatic, and
Runs out tokens remain hidden until 3% of their window has elapsed.

## Preferences notes
- Advanced: “Disable Keychain access” turns off browser cookie import; paste Cookie headers manually in Providers.
- Advanced: “Show provider storage usage” enables background scans of known provider-owned local paths; CodexBar only
  reports sizes and cleanup ideas, it does not delete files.
- Display: “Overview tab providers” controls which providers appear in Merge Icons → Overview (up to 6).
- If no providers are selected for Overview, the Overview tab is hidden.
- Providers → Claude: “Avoid Keychain prompts” selects the Security.framework reader's `Never prompt` policy.
- The lower-level “Keychain prompt policy” picker remains visible as the source of truth for Claude OAuth prompts.

## Widgets (high level)
- Widgets render shared usage snapshots for the supported widget families and
  provider picker; detailed pipeline in `docs/widgets.md`.

See also: `docs/widgets.md`.

Cost-history submenus keep tall histories in a scrollable viewport. Switching Token/Cost preserves the viewport; scrolling over the chart moves through the history without moving the native menu.

### Provider percent window

In Icon and Percent mode, provider settings expose an Auto, Session, or Weekly picker when the provider supports multiple quota windows. The choice updates top-level percent tokens in that provider’s layout. Conditional tokens and other providers’ layouts remain independent; use the layout editor for mixed percent windows.

### Inline cost chart inspection

Hover over a daily bar in a provider menu’s cost chart to inspect its date, cost, and token count. The highlighted day follows the pointer and clears when it leaves the chart; missing or unpriced values remain unavailable. This does not change cost collection or Settings charts.

### Daily spend ledger

Usage & Spend includes a daily ledger for each currency group. Rows use the selected bucket time zone and app language, retain priced days when another day is unpriced, and mark unavailable amounts with a dash. Zero-usage rows require established common coverage; unknown activity is not described as idle. Narrow settings windows allow horizontal ledger scrolling. Source filtering and dashboard accounting remain authoritative.

OpenCodex cost and request aggregates cover the selected history window, including All; older activity remains included alongside its token counts.

### Per-provider usage visibility

In each provider’s settings, **Visible usage items** selects which reported quota, usage, and credit rows appear in its menu, preview, and Overview. Rows are visible by default. Hidden rows that temporarily stop reporting remain individually restorable; **Restore Defaults** shows all rows again. These presentation choices sync with provider settings and do not change fetching, alerts, or quota calculations.

Usage-row visibility also filters compact account constraint details. Overall account headroom, severity, ordering, and recommendations continue to use all quotas.

Visibility and accent-color changes preserve account cache identity and retained spend, including when the changes arrive through config reload or sync. Credential and endpoint changes still invalidate their previous usage ownership.
