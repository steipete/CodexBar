---
summary: "Menu bar UI, icon rendering, and menu layout details."
read_when:
  - Changing menu layout, icon rendering, or UI copy
  - Updating menu card or provider-specific UI
---

# UI & icon

## Settings
- App copy, credential-expiry alerts, share cards, number formatting, and layout direction follow the selected app language. Widgets use the system language independently; all 23 supported languages have complete app catalogs and generated widget catalogs. After editing app translations or widget lookup keys, run `node Scripts/sync-widget-locales.mjs`; `make check` verifies key coverage, format arguments, plural branches, and generated resources.
- Notifications → Reset notifications is off by default and uses confirmed session and weekly resets, independently of confetti. Alerts name the provider and window; account labels appear only when Hide personal info is off. The existing macOS notification permission and Focus/Do Not Disturb settings control delivery; this toggle adds no startup permission request.
- Reset alerts and session-restored alerts share account-scoped reset receipts. Switching accounts establishes a fresh session-notification baseline. Known reset boundaries are persisted per provider, account, and window, preventing repeated banners after refreshes or restarts; a different account or a newly advanced boundary can notify independently. Without reset metadata, the existing detector requires a new usage cycle before notifying again; a new depleted episode can still produce a restored notice. Returning timestamps identify an already-announced cycle without replaying it, and previously announced boundaries stay deduplicated. The reset toggle supports portable preference export/import and remains local unless explicitly transferred.
- Usage & Spend places its time-range picker below the title and Refresh button, keeping the header readable in narrow settings windows.
- Spend charts group long ranges by week or month, support day/hour drill-down and account isolation, and keep an amount inspector visible below the chart. Reporting-calendar boundaries drive grouping and scrolling; the hourly view shows its UTC offset and a 24-hour clock. Chart sums are labeled recorded spend, and zero, unavailable, and incomplete amounts retain their distinct meanings.
- General → Preferred Currency supports Turkish lira (`TRY`, `₺`), New Zealand dollar (`NZD`), `SEK`, `NOK`, `DKK`, `PLN`, `BRL`, `MXN`, `ZAR`, `THB`, `IDR`, `VND`, and `UAH` alongside the existing currencies, using the shared daily exchange rates and offline fallback for cost estimates.
- General shows the app version and build beside Quit; About keeps its Version row even for Homebrew or unsigned builds.
- Provider accent colors use a hex field and a color picker that also previews the selected color; Reset restores the provider default.
- General → Default terminal supports installed Terminal, iTerm, Ghostty, and stable Warp. Terminal is the default and fallback. Warp launches target its app directly and use owner-only temporary tab configs, removed after one minute; interrupted-launch leftovers are cleaned on the next app start.
- Provider → Visible usage items includes titled provider detail sections. Choices persist across language changes and apply to provider cards and Overview. Untitled details remain visible; cost-summary sections stay controlled by their existing display setting.
- The empty SwiftUI Settings placeholder is dismissed once per presentation. Retained hidden windows are left alone; the real Settings window remains reusable.
- The placeholder never promotes the app to a Dock application or keeps it there. This avoids the launch-time Dock icon on macOS 27 when AppKit accepts promotion but refuses to restore accessory policy. Real Settings and update dialogs still request temporary Dock presence; the OS can still refuse demotion after those dialogs close.
- Usage & Spend heatmap tooltips prefer the space above the hovered cell and stay within the grid, falling below when needed. On narrow grids they compact vertically and may overlap cells; keyboard selection remains available in the daily grid.
- Token activity uses appearance-aware colors, brighter high-usage cells in Dark mode, and a slashed outline for unavailable history. The continuous annual grid keeps day cells at least 10 points wide with 3-point gaps; narrow cards scroll horizontally from the recent end and show labeled controls for earlier and more recent activity. The controls page with overlapping weeks, disable at each end, and disappear when the year fits. Month labels scroll with the grid, keyboard navigation reveals the active date, and tooltips stay inside the visible viewport.
- Calendar columns keep their chronological left-to-right order in right-to-left interfaces, so paging and keyboard date reveal follow the same coordinates as the drawn activity cells; surrounding controls retain the interface's layout direction.
- Both the application menu and status menu open About in the Settings window. An existing Settings window is reused
  and switches to the About pane.
- Homebrew-managed installs show an Updates section in About with the automatic-check toggle, Check for Updates, and the owning cask's status: checking, up to date, or "CodexBar x is available" with a prominent "Update to x" button. The menu shows the same "Update to x" action, then "Updating with Homebrew…" while `brew upgrade` runs; the app relaunches after verifying the installed version reached the offered update.
- If a Homebrew check or update fails, About shows the error and, when the active receipt identifies the cask, a selectable monospaced upgrade command for that cask with a trailing copy control. The control confirms successful copies briefly; copying does not run an update.

## Menu bar
- About CodexBar includes the running version. When the updater is available, the menu offers Check for Updates… or the existing staged-update action.
- Overview offers Share Usage Snapshot when its Usage & Spend summary has shareable data. The local preview uses the same spend sources, hidden-source choices, calendar, and currency as that summary; Copy Image exports PNG and TIFF without uploading anything.
- Shared cards and copied statistics keep model families from providers with complete model history, even when another provider in the same currency has unpriced or incomplete history. A ranking that omits providers or model rows is labeled **PARTIAL** on the image and **Top models (partial)** in copied text; complete rankings retain **BY USAGE**. Selected-day model rows are omitted because the shared totals describe the full reporting window.
- LSUIElement app: no Dock icon; status item uses custom NSImage.
- Cached status menus and previously opened submenus follow macOS appearance changes before reopening, preserving the effective Light/Dark and accessibility appearance.
- Merge Icons toggle combines providers into one status item with a switcher.
- Menu Bar → Combined icon source offers Current selection (default), Highest usage, and Frontmost provider app. The last option follows enabled Codex, Claude, Cursor, and Antigravity desktop apps only while the merged icon is collapsed. Unknown or disabled apps fall back to the saved selection or Overview. Opening the menu preserves its provider, account, and Overview selection; focus never saves a new selection. Stacked and separate icons do not monitor focus. Monitoring uses macOS application notifications, without polling, permission prompts, or terminal-tab inspection. Existing highest-usage preferences are preserved, and the choice supports sync and portable preference transfer.
- With separate icons, explicitly reordering providers in Settings reassigns CodexBar's saved menu bar slots in that order, from right to left. Recreated items retain their stable autosave and accessibility identities. Orders changed while icons are merged also update these saved slots before returning to separate icons. Ordinary refreshes and visibility recovery continue to preserve manual Command-drag placement.
- With the automatic metric selected, switcher progress honors a provider's exhausted-quota selection before
  showing normal weekly progress. OpenCode Go's automatic percentage and switcher use the least remaining
  five-hour, weekly, or monthly allowance even before exhaustion. Explicit choices and separate provider pools
  retain their existing selection rules.
- Normal quit removes status items with their stable identities intact, preventing retained blank menu bar slots on macOS 26.6.2 while preserving saved placement.
- Status items receive stable autosave names before normal sizing, including during visibility recovery. Saved
  positions beyond the widest attached display plus 512 points are cleared before creation. Visibility changes and
  removal validate positions before saving and after AppKit updates them: a missing or invalid result restores only
  a valid previous position. Valid new positions remain untouched; unrelated defaults are never repaired by this path.
- When Overview has selected providers, the switcher includes an Overview tab that renders up to 6 provider rows.
- Overview row order follows provider order; selecting a row jumps to that provider detail card.
- Menu → Overview layout offers Detailed (default) and Compact. Compact keeps provider/account headers and labeled quota bars, omits their reset/detail lines and supplemental sections, and retains detail-only providers. Select a provider for its full card. Visibility choices and the shared Usage & Spend summary continue to apply.
- Menu-card wrappers use standard non-vibrant view behavior so white GPU-tinted Overview content remains visible on macOS 15. Overview selection stays outside the SwiftUI graph, with native submenu click and drag tracking retained.
- The global open-menu keyboard shortcut toggles the currently tracked menu closed before opening a new one.
- Display → Menu Bar → Layout provides presets plus a token editor. Tokens can be clicked to append, dragged from the
  palette, reordered between one or two lines, dragged out, or removed with Delete. Layouts can be global or overridden
  per provider. Manual edits select the Custom preset.
- For Codex or Claude weekly usage without a `W` prefix, select that provider in Layout, remove the existing percentage,
  and add the **second Weekly %** chip from Usage (the provider's secondary lane). Repeat for the other provider
  if needed. The first **Weekly %** is a semantic window token and keeps its prefix; lane tokens omit it.
  For Antigravity's two independent families, add **Gemini weekly %** and **Claude/GPT weekly %**;
  both appear when known weekly quota-summary data is available. The separate Gemini provider reports
  Pro/Flash quotas, not these Antigravity family allowances; it does not synthesize a weekly quota.
- Layout palette chips use their natural label widths and wrap into rows instead of squeezing longer token names into equal-width columns.
- Time tokens offer Session and Weekly variants of Resets in and Reset at, including in conditional branches.
  The original unqualified reset tokens continue to follow the automatic window. A selected window that is
  unavailable displays a dash rather than substituting another window. Cursor also exposes **Grok Bot %**
  while its named allowance is available; a saved token shows its label and a dash when unavailable. Saved layouts use V4 keys
  alongside a V3 projection that drops named-extra tokens but keeps explicit reset selections, and a
  v0.56.8-readable V2 projection, which omits the new tokens and conditional rules that use them while preserving
  existing conditional placements, direct lane selections, and other providers' overrides. Re-upgrading restores
  the full layout unless an older release changed its saved projection. The oldest-format projection is also retained.
- All providers previews the default layout and lists enabled providers with saved overrides, even when an override
  currently matches the default. Each “Use all-providers layout” action removes only that provider's override;
  global edits preserve overrides, and disabled providers are left untouched. Before a default is first saved,
  editing still starts from the representative provider's effective layout.
- Small/Regular controls the token font scale. Tight/Regular controls status-item padding. Compact stacked uses two
  tightly spaced lines sized to fit the menu bar.
- Size, gap, and vertical adjustment share a compact options row. The Layout section footer keeps the token-editing
  instructions, including selecting a placed token and pressing Delete to remove it.

### Layout tokens

| Group | Tokens | Behavior |
| --- | --- | --- |
| Identity | Icon, Provider name, Account | Provider-scoped branding and identity |
| Usage | Session %, Weekly %, Scoped weekly %, Auto %, Usage bar | Window percentage or a compact three-glyph usage bar |
| Usage | Named allowances (Cursor Grok Bot, Antigravity family weekly quotas) | Own label and percentage; a saved selection shows a dash when unavailable |
| Usage | Session pace, Weekly pace, Auto pace | Signed pace delta for that window |
| Time | Resets in, Reset at (automatic, Session, Weekly), Runs out | Selected-window relative reset, absolute reset, or pace estimate |
| Money | Balance, Cost today, Cost 30d | Provider balance or remaining credits, or local cost estimate for the selected period |
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

Enable **Color by provider** under **Menu Bar → Icon** to tint each provider slot with its accent color, including custom accents. This single toggle defaults off and works with Critters, Meter bars, and Icon & percent, including stacked provider rows; it never changes the saved layout or the Brand/Monochrome artwork used in Usage & Spend. Pace tokens keep their independent green/red colors and VoiceOver keeps the same spoken labels.

Provider color falls back to monochrome while a menu is open, data is stale, system Increase Contrast is enabled, or the inactive-display contrast option is enabled. Color returns immediately when the menu closes. Accents must meet a 2:1 contrast threshold against conservative reference backgrounds (25% sRGB gray in dark appearance, 85% in light appearance); this is not a WCAG text-conformance claim or wallpaper sampling. Unsupported or low-contrast accents use the system template rendering. The layout preview follows its own light/dark and accessibility environment.

Balance uses the same provider amount as the menu card: Codex credits, OpenRouter remaining credits, MiMo,
DeepSeek, DeepInfra, Moonshot, Poe points, Hypercredits, LithosAI prepaid balance, Atlas Cloud and Vercel available balances, or OpenCode Go's
Zen balance. DevPass shows remaining billing-cycle credits (a plan allowance); Mistral shows monthly API spend.
An explicit Balance token remains available alongside quota percentages. Missing amounts render a dash;
unrelated spend is never substituted. Conditional balance thresholds remain OpenRouter-only. Auto %
uses the same provider-aware automatic-window resolution as the legacy menu bar metric setting. For balance-only
providers, Auto % shows the available money, points, or API spend instead of inventing a quota percentage. Both the
status item and editor preview preserve real quota percentages when a usable limit exists. When a reset token
falls back to that same balance, a visible Auto % token shows it once; reset-only layouts keep the balance fallback. If a snapshot
does not provide a token's data, that token renders an en dash while its siblings remain visible. Existing installs
derive their first layout from the prior style, display mode, metric, and reset settings; those legacy keys remain
untouched for downgrade safety, while a saved token layout takes precedence.

For Abacus, explicitly selecting Credits keeps the monthly allowance visible. With 250 of 1,000 credits used, it
shows `C 75%` remaining (or `C 25%` with Show usage as used). Its billing window and reset date still drive pacing;
Automatic keeps its existing percentage. Credits labels also apply to editor tokens, conditional metrics and pace
accessibility.

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
- Cards with a history submenu show the active menu selection; deselecting the card clears it. Credits and other sections are separate menu items, so selecting usage does not highlight them.
- Two-column statistics headings wrap to keep the full localized label readable, including estimated current-window tokens.
- Provider-specific rows with resets (countdown by default; optional absolute clock display). Primary, secondary,
  tertiary, and extra windows render when the provider snapshot has data for them.
- Manual refresh updates the open card subtitle and persistent Refresh-row spinner in place. Repeated clicks share the
  active request, and the existing row geometry remains fixed through success or failure.
- Live pace and metric detail text use the full row width. Updates that exceed the space reserved when the menu opened
  show a trailing ellipsis; reopening the menu measures the updated text again.
- Codex credits can add a separate “Buy Credits…” menu action.
- Claude capped Extra Usage follows the used/remaining fill preference; spending amounts and “% used” copy stay unchanged.
- Codex OpenAI web extras: code review remaining and usage breakdown render when dashboard data is attached.
- Codex and Claude cost cards: a Recent windows list under the daily bars shows each quota window's
  range, cost, and tokens (Current window, Previous window, N windows ago), split at official and banked resets.
  Inferred boundaries are labeled estimated; incomplete local subtotals show ≥ and a partial-estimate note.
  Without weekly reset metadata, the existing calendar cost history remains visible.
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

In Icon and Percent mode, provider settings expose a **Menu bar metric** picker when the provider supports multiple quota windows. Alongside Auto, Session, and Weekly, it offers the provider's declared named allowances: Cursor's Grok Bot and Antigravity's Gemini weekly and Claude/GPT weekly quotas. These choices remain available before a reading arrives. The choice updates top-level percent tokens in that provider’s layout and persists through its existing layout override. Named allowances render their own label and percentage, with an en dash for missing or unknown data and a real zero preserved. Balance, reset, conditional tokens, and other providers’ layouts remain independent; use the layout editor for mixed percent windows.

### Inline cost chart inspection

Hover over a daily bar in a provider menu’s cost chart to inspect its date, cost, and token count. The highlighted day follows the pointer and clears when it leaves the chart; missing or unpriced values remain unavailable. This does not change cost collection or Settings charts.

### Daily spend ledger

Long ranges initially show the newest 30 daily rows. **Show all** expands the complete ledger and **Show less** collapses it again; chart data, totals, exports, and coverage still use the full selected reporting period. Provider icons share one tooltip listing the day's active providers.

Usage & Spend includes a daily ledger for each currency group. Rows use the selected bucket time zone and app language, retain priced days when another day is unpriced, and mark unavailable amounts with a dash. When one source on a day has no price, the row shows the known spend of the other sources with a tilde, the same partial marker as the group total. A day with no known spend keeps the dash. Zero-usage rows require established common coverage; unknown activity is not described as idle. Narrow settings windows allow horizontal ledger scrolling. Source filtering and dashboard accounting remain authoritative.

OpenCodex cost and request aggregates cover the selected history window, including All; older activity remains included alongside its token counts. Imported requests without token evidence retain the other models' known subtotals and mark the model breakdown as partial. Missing-usage counts propagate through daily, session, window, CLI, and exported totals; sharing excludes incomplete model rankings. Explicit zero usage stays known, and numeric overflow is not reclassified as missing usage. Cached imports apply the same accounting without rereading unchanged logs.

### Per-provider usage visibility

In each provider’s settings, **Visible usage items** selects which reported quota, usage, and credit rows appear in its menu, preview, and Overview. Rows are visible by default. Hidden rows that temporarily stop reporting remain individually restorable; **Restore Defaults** shows all rows again. These presentation choices sync with provider settings and do not change fetching, alerts, or quota calculations.

Usage-row visibility also filters compact account constraint details. Overall account headroom, severity, ordering, and recommendations continue to use all quotas.

Visibility and accent-color changes preserve account cache identity and retained spend, including when the changes arrive through config reload or sync. Credential and endpoint changes still invalidate their previous usage ownership.
