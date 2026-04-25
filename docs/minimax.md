---
summary: "MiniMax provider data sources: API token or browser cookies + coding plan remains API."
read_when:
  - Debugging MiniMax usage parsing
  - Updating MiniMax cookie handling or coding plan scraping
  - Adjusting MiniMax provider UI/menu behavior
---

# MiniMax provider

MiniMax supports API tokens or web sessions. Usage is fetched from the Coding Plan remains API using
either a Bearer API token or a session cookie header.

## Data sources + fallback order

1. **API token** (preferred)
  - Set in Preferences → Providers → MiniMax (stored in `~/.codexbar/config.json`) or `MINIMAX_API_KEY`.
  - When present, MiniMax uses the API token and ignores cookies entirely.
2. **Cached cookie header** (automatic, only when no API token)
  - Keychain cache: `com.steipete.codexbar.cache` (account `cookie.minimax`).
3. **Browser cookie import** (automatic)
  - Cookie order from provider metadata (default: Safari → Chrome → Firefox).
  - Merges Chromium profile cookies across the primary + Network stores before attempting a request.
  - Tries each browser source until the Coding Plan API accepts the cookies.
  - Domain filters: `platform.minimax.io`, `minimax.io`.
4. **Browser local storage access token** (Chromium-based)
  - Reads `access_token` (and related tokens) from Chromium local storage (LevelDB) to authorize the remains API.
  - If decoding fails, falls back to a text-entry scan for `minimax.io` keys/values and filters for MiniMax JWT claims.
  - Used automatically; no UI field.
  - Also extracts `GroupId` when present (appends query param).
5. **Manual session cookie header** (optional override)
  - Stored in `~/.codexbar/config.json` via Preferences → Providers → MiniMax (Cookie source → Manual).
  - Accepts a raw `Cookie:` header or a full "Copy as cURL" string.
  - When a cURL string is pasted, MiniMax extracts the cookie header plus `Authorization: Bearer …` and
  `GroupId=…` for the remains API.
  - CLI/runtime env: `MINIMAX_COOKIE` or `MINIMAX_COOKIE_HEADER`.

## Endpoints

- API token endpoint: `https://api.minimax.io/v1/coding_plan/remains`
  - Requires `Authorization: Bearer <api_token>`.
- Global host (cookies): `https://platform.minimax.io`
- China mainland host: `https://platform.minimaxi.com`
- `GET {host}/user-center/payment/coding-plan`
  - HTML parse for "Available usage" and plan name.
- `GET {host}/v1/api/openplatform/coding_plan/remains`
  - Fallback when HTML parsing fails.
  - Sent with a `Referer` to the Coding Plan page.
  - Adds `Authorization: Bearer <access_token>` when available.
  - Adds `GroupId` query param when known.
- Region picker in Providers settings toggles the host; environment overrides:
  - `MINIMAX_HOST=platform.minimaxi.com`
  - `MINIMAX_CODING_PLAN_URL=...` (full URL override)
  - `MINIMAX_REMAINS_URL=...` (full URL override)

## Cookie capture (optional override)

- Open the Coding Plan page and DevTools → Network.
- Select the request to `/v1/api/openplatform/coding_plan/remains`.
- Copy the `Cookie` request header (or use “Copy as cURL” and paste the whole line).
- Paste into Preferences → Providers → MiniMax only if automatic import fails.

## Notes

- Cookies alone often return status 1004 (“cookie is missing, log in again”); the remains API expects a Bearer token.
- MiniMax stores `access_token` in Chromium local storage (LevelDB). Some entries serialize the storage key without a scheme
(ex: `minimax.io`), so origin matching must account for host-only keys.
- Raw JWT scan fallback remains as a safety net if Chromium key formats change.
- If local storage keys don’t decode (some Chrome builds), the MiniMax-specific text scan avoids a full raw-byte scan.

## Cookie file paths

- Safari: `~/Library/Cookies/Cookies.binarycookies`
- Chrome/Chromium forks: `~/Library/Application Support/Google/Chrome/*/Cookies`
- Firefox: `~/Library/Application Support/Firefox/Profiles/*/cookies.sqlite`

## Snapshot mapping

- Primary: percent used from `model_remains` (used/total) or HTML "Available usage".
- Window: derived from `start_time`/`end_time` or HTML duration text.
- Reset: derived from `remains_time` (fallback to `end_time`) or HTML "Resets in …".
- Plan/tier: best-effort from response fields or HTML title.

### Coding Plan multi-model (`model_remains[]`)

- The remains API returns **one row per quota** (text, VLM, search, TTS HD, video, music, image, lyrics, coding-plan modules, etc.). CodexBar decodes **every** row into `MiniMaxUsageSnapshot.models` while keeping the **existing scalar fields** (`availablePrompts`, `usedPercent`, `resetsAt`, …) aligned with **`model_remains[0]`** for the menu bar icon / primary `UsageSnapshot`.
- Field semantics match the existing parser: `current_interval_total_count` is the window cap, `current_interval_usage_count` is treated as **remaining** in this codebase, and **used = total − remaining** (same as before).
- If interval counts are partially missing (for example, API omits `current_interval_usage_count`), the row keeps usage percent as **unknown** instead of coercing to `0% used` / `100% left`. Detail text can still show `—/total` when total is known.
- Optional **weekly** columns (e.g. TTS): `current_weekly_total_count` and `current_weekly_usage_count` (weekly **remaining**, same naming convention as the interval fields). When present, the menu card shows a secondary “↳ Weekly …” line under that row.
- When weekly fields are **absent-or-zero in aggregate** (at least one key present, and both numeric values are 0 when treating missing as 0), CodexBar treats that as **no weekly cap**: weekly quota fields are cleared and no weekly usage line is shown (avoids misleading `0/0`, `0/—`, etc.).
- Rows are grouped in the menu card by inferred window: **5-hour** (`windowMinutes == 300`), **daily** (~24h window), **weekly** (weekly-only rows), **other**.

### Providers settings mirror (Preferences → Providers → MiniMax)

- The Providers detail **Usage** section mirrors the same `model_remains[]` grouping as the menu card (**5-hour**, **Daily**, **Weekly**, **Other**), with the same per-row progress bar, `used/total (remaining)` detail line, reset text, and optional weekly secondary line.
- Preferences does **not** reuse the menu card’s collapsible section headers; if the combined row count is **≥ 6**, the block is wrapped in an embedded `ScrollView` (max height ≈ 360 pt) so the window stays manageable.
- MiniMax row titles in Preferences use a **separate fixed-width title column** instead of the global usage label width. The width is the rendered width of `code-plan-search`; longer model names **wrap onto multiple lines inside that fixed column** instead of tail-truncating, so the progress/detail column keeps a stable width without hiding the full name.

### Menu-bar card layout (MiniMax-only)

- When `minimaxSections` is present, the card wraps **metrics + usage notes + multi-model sections** in an internal vertical `ScrollView`. The scroll region first **measures the rendered content height** and then applies an explicit frame height of `min(actualContentHeight, min(640, max(320, NSScreen.main.visibleFrame.height − 310)))`. This means the card **shrinks to fit** when collapsed/short and **scrolls only when content exceeds the cap**. The **header** (provider name / account / plan) stays **above** this scroll region so account context remains visible while scrolling.
- Each grouped section (**5-hour window**, **Daily quota**, **Weekly quota**, **Other windows**) has a tappable header with a chevron. **Collapsed** headers show **`N items`** on the right. Default: **collapsed** when that section has **≥ 5** rows; **expanded** otherwise. The user’s toggle is stored in-process in `MiniMaxSectionCollapseStore` (keyed by section title); it resets on app quit.
- Toggling a section invalidates and remeasures the hosting `NSMenuItem` view while the menu is open, so the MiniMax card **shrinks immediately when collapsing** and **grows immediately when expanding** instead of keeping the initial height.
- This layout keeps the total `NSMenu` height bounded so app-level items below the card (e.g. Usage Dashboard, Refresh, Settings) remain reachable without relying on the menu’s own overflow chevrons.
- In merged **Overview** mode, MiniMax section header taps (collapse/expand) are handled as in-card interactions and must not trigger the row-level provider-selection action.

## Key files

- `Sources/CodexBarCore/Providers/MiniMax/MiniMaxUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/MiniMax/MiniMaxModelUsage.swift`
- `Sources/CodexBarCore/Providers/MiniMax/MiniMaxProviderDescriptor.swift`
- `Sources/CodexBar/Providers/MiniMax/MiniMaxProviderImplementation.swift`
- `Sources/CodexBar/MiniMaxUILayoutMetrics.swift`
- `Sources/CodexBar/MiniMaxSectionCollapseStore.swift`
- `Sources/CodexBar/MiniMaxMenuCardViews.swift` (分组折叠 + 行视图)
- `Sources/CodexBar/UsageMenuCardViewModel+MiniMax.swift` (`model_remains[]` → 菜单模型)
- `Sources/CodexBar/MenuCardView.swift`（MiniMax 卡片区滚动）
- `Sources/CodexBar/PreferencesProviderDetailView.swift` (Providers → MiniMax usage mirror)

