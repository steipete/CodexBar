---
summary: "Cursor provider data sources, external-browser account switching, and cursor.com APIs."
read_when:
  - Debugging Cursor usage parsing
  - Updating Cursor cookie import or session storage
  - Adjusting Cursor provider UI/menu behavior
---

# Cursor provider

The opt-in **Frontmost provider app** merged-icon source recognizes Cursor.app (`com.todesktop.230313mzl4w4u92`) when Cursor is enabled. It changes only the collapsed icon, preserving menu and account selection.

Cursor can reuse Cursor.app's local session or a cursor.com browser session. On macOS, automatic mode prefers a usable
Cursor.app session and falls back to cookies when the app token is missing, expired, invalid, or rejected. On Linux,
automatic mode uses cached or stored cookies when available, then falls back to the signed-in Cursor app token, then to
`cursor-agent`'s, because browser import is unavailable.

Settings omits the Version row because this provider reads web APIs and does not detect a local app or CLI version.

## Data sources + fallback order

Manual cookie configuration is always the explicit override. The automatic order is Cursor.app → cached cookie → browser
cookie import → stored session on macOS, and cached cookie → stored session → Cursor.app token → `cursor-agent` token on
Linux. Explicit `web` mode never reads local Cursor credentials; macOS uses its cookie ladder, while Linux requires a configured manual cookie.

1) **Cursor.app local auth** (first automatic source on macOS; Linux fallback)
   - Reads Cursor.app's VS Code-style global state DB for `ItemTable` key `cursorAuth/accessToken`.
   - On macOS, supports both plain JWTs and Cursor 3.27's `cursor-safe-storage:v1:` encrypted tokens. Encrypted
     tokens use the `Cursor Safe Storage` Keychain item (account `Cursor`). Plain token decoding performs no
     Keychain reads.
     Background and settings refreshes never prompt. An explicit manual refresh may request access once, sharing
     that action's prompt allowance with browser imports. Choose **Always Allow** to permit future refreshes without
     another prompt; denying access keeps the six-hour cooldown, including subsequent manual refreshes.
     Unreadable or malformed encrypted tokens fall through to the existing cookie sources without reusing an older
     persisted Cursor.app identity. JWT user ID and expiry validation still run after decryption.
   - BLOB decoding recognizes BOM-less ASCII UTF-16LE tokens before UTF-8, which would otherwise keep interleaved
     NUL bytes. Other encodings retain the existing UTF-8/UTF-16LE fallback; tokens are not normalized, and malformed
     nonempty values remain distinct from a missing session so they cannot enable stale cached-account fallback.
   - Files consulted by SQLite:
     - macOS main DB: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
     - Linux main DB: absolute `$XDG_CONFIG_HOME/.../state.vscdb`, else absolute `$HOME/.config/...`, else account-home `.config/...`
     - Active WAL sidecars when present: `state.vscdb-wal` and `state.vscdb-shm`
   - The database is opened read-only. Active WAL state is read normally; an idle WAL-mode main file with no
     sidecars uses SQLite immutable mode so CodexBar does not recreate files in Cursor's directory.
   - The token is used only while its JWT expiry is more than 60 seconds away. CodexBar never refreshes it.
   - On macOS, a validated derived session is also persisted owner-only at
     `~/Library/Application Support/CodexBar/cursor-session.json` through the standard credential-file writer. Linux
     reads the Cursor database directly and does not persist the app token.
   - When an already-cached cookie exposes a different email or subject, CodexBar logs the mismatch and keeps the
     chosen Cursor.app identity on the usage snapshot/card. It does not combine app usage with browser identity.
   - Temporary transport failures keep the previous usage measurement and its timestamp for an unchanged account,
     including when the network message is localized. The same policy applies to stored sessions; rejected sessions
     still follow the normal sign-in recovery path.

2) **Cached cookie header**
   - Stored after successful browser import.
   - Keychain cache: `com.steipete.codexbar.cache` (account `cookie.cursor`).

3) **Browser cookie import** (macOS only)
   - Cookie order from provider metadata, falling back to SweetCookieKit's default browser catalog, including Aside, Opera, Opera Neon, and Ego Lite.
   - Domain filters: `cursor.com`, `cursor.sh`.
   - Cookie names required (any one counts):
     - `WorkosCursorSessionToken`
     - `__Secure-next-auth.session-token`
     - `next-auth.session-token`

4) **Stored session cookies** (legacy fallback on macOS and Linux)
   - Legacy sessions captured by older CodexBar releases remain readable.
   - Stored in the platform Application Support directory: `~/Library/Application Support/CodexBar/cursor-session.json` on
     macOS, or `$XDG_DATA_HOME/CodexBar/cursor-session.json` on Linux (default: `~/.local/share/CodexBar/cursor-session.json`).

On macOS, explicit `--source web` skips Cursor.app local auth and uses only the cookie ladder. On Linux, explicit `web`
requires a configured Manual cookie and never reads the app token. `codexbar usage --provider cursor --source auto --verbose`
prints the selected automatic path and is the quickest live-read check after Cursor login.

Manual option:
- Preferences → Providers → Cursor → Cookie source → Manual.
- Paste the `Cookie:` header from a cursor.com request.

## Add and switch account
- **Add Account** opens `https://authenticator.cursor.sh/` in a supported browser.
- Aside, Opera, and Opera Neon are supported with SweetCookieKit 0.5.5. The selected application's bundle identifier pins login to that browser's cookie store.
- SweetCookieKit 0.5.6 adds Ego Lite cookie imports. Add/Switch Account does not offer Ego Lite until its application has a verified, unambiguous bundle-identifier mapping; display names and storage paths are insufficient for interactive login.
- **Switch Account** opens the same authenticator and waits for a different stable account ID when available, falling back to normalized email when IDs are unavailable.
- When the system's HTTPS handler is a supported browser, CodexBar opens the route there automatically. When the handler is an intermediary app, CodexBar asks the user to choose a concrete supported browser before opening the route.
- CodexBar pins the original HTTPS route to that concrete browser and polls cookies only from the same application. Interactive login never falls back to another browser, a stored session, or Cursor.app; cancelling browser selection or the absence of a supported browser stops before login opens.
- An installed non-Safari browser remains eligible before its first profile or cookie database exists, and CodexBar detects the store created during login. Browsers with access-blocked profile data remain unavailable, while Safari still requires an existing readable cookie source.
- CodexBar preserves its cached and legacy stored Cursor sessions while login is in progress. An accepted browser session must be durably cached before the legacy session is cleared, so cancellation or failure leaves the previous session intact. Add completes only after the authenticated response includes a Cursor account identity. Switch compares stable account IDs when both sides provide them and otherwise compares normalized email.
- CodexBar checks all available profiles in the selected browser. Add accepts a sole unambiguous account automatically, while Switch always asks for confirmation before replacing the current account, even when only one eligible alternative is found. Multiple eligible accounts always require an explicit choice, and CodexBar caches only the chosen session.
- A successful add or switch selects the Automatic cookie source. Saved manual headers and token accounts remain
  stored but passive: they do not override browser fetching, cached usage, quota warnings, or utilization/reset
  ownership. Explicitly selecting a saved token account switches Cursor back to Manual and reactivates it.

## API endpoints
- `GET https://cursor.com/api/usage-summary`
  - Plan usage (included), on-demand usage, billing cycle window.
- `GET https://cursor.com/api/auth/me`
  - Stable user ID, email, and name.
- `GET https://cursor.com/api/usage?user=ID`
  - Legacy request-based plan usage (request counts + limits).
- `GET https://cursor.com/api/dashboard/v2/usage-status?scope=user`
  - Optional monthly additional spend for unified personal memberships; failures retain usage-summary data.
- `POST https://cursor.com/api/dashboard/get-sand-usage-status`
  - Grok Bot weekly included usage (`usagePercent`, `nextResetTimestampUtc`). Same session cookie;
    requires `Origin: https://cursor.com`. Best-effort: a failure leaves Cursor's monthly bars intact.
  - `isUnified: true` marks The X Subscription's shared weekly pool. When no valid request quota is present,
    a usable pool with a current reset becomes the primary **Weekly** bar and replaces the stale monthly
    Total/Cursor/Third Party bars; on-demand spend stays in the cost section.

## Cookie file paths
- Safari: `~/Library/Cookies/Cookies.binarycookies`
- Chrome/Chromium forks: `~/Library/Application Support/Google/Chrome/*/Cookies`
- Firefox: `~/Library/Application Support/Firefox/Profiles/*/cookies.sqlite`

## Linux CLI
- Automatic usage (`codexbar usage --provider cursor`) supports the signed-in Cursor app and `cursor-agent` on Linux after
  manual, cached, and stored sessions have been considered.
- Authentication order: manual cookie header → cached session → stored session → Cursor app access token →
  `cursor-agent` access token.
- The `cursor-agent` token is the `accessToken` that `cursor-agent login` keeps in `cursor/auth.json` under the same
  config home as the app database (absolute `$XDG_CONFIG_HOME`, else `~/.config`). It is used when the app has no usable
  token or cursor.com rejects that token with HTTP 401/403, so a machine with only the Cursor CLI gets usage too. A missing,
  unreadable, or malformed local store does not hide the next login. Other API failures stop the fetch without switching
  accounts. The file is read-only; CodexBar never refreshes tokens, changes permissions, or writes either credential store.
  Owner-readable files (including mode 0600) and symlinked auth files are supported. Missing or empty `accessToken` values
  provide no session; agent tokens use the same JWT identity and expiration checks as desktop tokens. Expired or invalid
  tokens are not sent, and exhausted local logins retain the existing missing-session error; run `cursor-agent login` to
  replace an expired agent login.
- Linux requests use a reusable HTTP session with automatic cookie storage disabled, so a long-running `serve` process cannot replace the selected credential with cookies left by earlier responses.
- The app token is read from absolute `$XDG_CONFIG_HOME/Cursor/User/globalStorage/state.vscdb`, then `$HOME/.config/...` when `HOME` is absolute, then the account home’s `.config/...`. Relative `XDG_CONFIG_HOME` / `HOME` values are ignored. The database is read-only; expired app tokens are not refreshed by CodexBar.
- Cursor usage includes the Grok Bot weekly allowance and reset time when the account exposes it. Grok Bot endpoint failures do not hide Cursor usage.
- Explicit `--source web` requires a manual cookie and never reads the app token.
- Automatic browser cookie import and the external-browser Add/Switch flow remain macOS app features.
- Manual cookie headers from `~/.config/codexbar/config.json` (or legacy `~/.codexbar/config.json`) work on Linux.

## Local storage footprint
When **Settings → Advanced → Track provider local storage** is enabled on macOS, CodexBar measures:
- `~/Library/Application Support/Cursor`
- `~/Library/Application Support/Caches/cursor-updater`
- `~/.cursor`
- `~/Library/Caches/Cursor`
- `~/Library/Caches/com.todesktop.230313mzl4w4u92`
- `~/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt`
- `~/Library/Caches/cursor-compile-cache`
- `~/Library/HTTPStorages/com.todesktop.230313mzl4w4u92`

The storage detail lists measured paths and their sizes. CodexBar does not delete Cursor data.

## Token cost (dashboard API)
The cost summary's Cursor section is opt-in: it only fetches when **Show cost summary** is enabled and the Cursor provider is on.
Unlike Claude and Codex cost (scanned from local session logs on this machine), Cursor cost is remote, account-wide data from the cursor.com dashboard, so it covers usage from every machine on the account.

Auth reuses the exact status-probe session resolution and cookie-source policy:
- **Auto**: Cursor.app local auth → cached cookie header → browser cookie import → stored session.
- **Manual**: a non-empty pasted cookie header is required and forwarded as-is, so cost and status share the same session; an empty header fails closed instead of falling back to another account.
- **Off**: the fetch is skipped in the app; `codexbar cost --provider cursor` fails explicitly and `/cost` returns a provider error row.

Fetch behavior:
- `POST https://cursor.com/api/dashboard/get-filtered-usage-events` (cookie-authenticated; requires a matching `Origin` for CSRF).
- Pages of 1000 events (up to 200 pages), with exact page-boundary overlap removed before aggregation. Reaching the safety cap or otherwise receiving fewer events than Cursor reports fails the refresh instead of publishing a partial total.
- Empty query windows return `{}`; empty terminal pages omit the event array but retain `totalUsageEventsCount`. Both shapes were verified against populated pages from the same live session. The decoder accepts only these exact omitted-array shapes, preserves the query count, and rejects malformed arrays or ambiguous envelopes; a terminal `{}` contradicting an earlier positive count still fails.
- The window start is snapped to the local day boundary so a 1-day window covers all of today and wider windows keep their full first day.
- All-history requests clamp the lower bound to the Unix epoch for the dashboard API, preserving all Cursor history without sending the shared period model's pre-epoch sentinel. Rolling and month-to-date windows retain their selected cost-bucketing time zone.

Two totals are reported from the same events:
- **API-rate estimate**: reported `tokenUsage.totalCents`, with an API-list-price fallback only when the field is missing or null. Fallbacks use the existing cached models.dev catalog or bundled rates at the event date, preserve Cursor's disjoint input/cache counters, and do not read native Codex custom pricing or refresh prices over the network. Reported zero remains zero; malformed, negative, nonfinite, or otherwise invalid costs stay unpriced and fail the same-model sum closed. Unknown models remain unpriced. Reported, estimated, and unpriced request counts remain visible even when a rejected cost invalidates a model total.
- **Cursor-metered** (`meteredCostUSD`): what Cursor's plan actually deducts over the window, shown as its own "Cursor-metered:" line.
- Metered-only request events remain visible even when Cursor does not include token details; cookie/config resolution failures stop the fetch instead of falling back to another session.

API-list-price estimates are not estimates of actual Cursor charges: they do not apply plan-specific Cursor Token Rates, regional adjustments, or legacy billing rules. `chargedCents` and Cursor-metered totals remain separate and unchanged. In Overview, history coverage describes the included sources' established history; a selected subscription without spend still makes amounts partial and remains disclosed in the subscription count, without erasing another source's known history days.

Caching: automatic cost refreshes follow the app's token-cost cadence, with a minimum interval of 15 minutes (30 minutes in Low Power Mode). Snapshots are scoped to the history window, cookie source, and resolved account (manual-cookie hash or auto-mode account fingerprint), so switching accounts or pasting a new cookie invalidates them immediately.

An HTTP 403 from the cost endpoint records a failed cost source with an in-memory retry time at least six hours later, even when no cost snapshot is available. It does not invalidate the working quota session or change local CSV fallback. Manual and menu-open refreshes bypass the cooldown, and a changed account, credential source, history window, timezone, or provider configuration permits a new attempt. Timed-out cost scans keep their normal cooldown without a snapshot; transient failures retain their normal retry behavior. Restarting the app clears this in-memory cooldown.

If Auto fetches usage with a cookie that the app still cannot confirm for the current account, the result stays unpublished. An unchanged account scope waits for the next normal or manual refresh instead of repeatedly forcing another request. Real account, history-window, provider, or cost-timezone changes still request a replacement; a successful fetch that confirms its own cookie can publish immediately.

## Snapshot mapping
- Primary: a valid legacy request quota takes precedence. Otherwise, use plan usage percent (included plan), or the shared weekly pool for `isUnified: true` accounts with a current weekly reset. Missing or expired timing retains the prior monthly layout.
- Secondary: Cursor (Cursor models) usage percent on legacy plans; unified weekly accounts omit the stale monthly breakdown.
- Tertiary: Third Party usage percent.
- Extra: Grok Bot usage from `get-sand-usage-status` when the account has a paid allowance or an unexpired trial. The current `includedLimitZero` field takes precedence over the older allowance flag. Exhausted active trials remain visible; missing, malformed, or expired trial dates do not grant an allowance. Grok Bot is not the semantic weekly window, so monthly Cursor Auto pace stays on the Cursor bar when this extra 7-day window is present. Paid 7-day Grok Bot extras still show weekly pace on that extra bar; trial extras without a recurring reset do not. Paid Grok Bot allowances with a valid reset use the documented 7-day cadence regardless of `currentPeriodStart`, so pace covers the full week even when that field starts mid-week or is missing. Missing or malformed reset dates leave pace unavailable.
- Provider cost: Extra usage USD. A capped individual budget wins; team accounts without a user cap use the shared team on-demand budget.
- Reset: billing cycle end date for monthly bars; paid Grok Bot uses `nextResetTimestampUtc`, even if a trial-expiry field is also present. Trial-only allowances have no recurring reset or duration because trial expiration does not replenish quota.

## Menu-bar layout

In Icon and Percent mode, choose **Providers → Cursor → Menu bar metric → Grok Bot** to replace the
ordinary percentage in Cursor's layout. This saves a Cursor-only override. The layout editor also offers
**Grok Bot %** in the usage palette when an allowance is available, for layouts with multiple percentages.
Saved Grok Bot selections continue to read the same allowance after it becomes the unified primary pool.
Both paths show the allowance's short tag, for example `GB 42%`, and follow the used/remaining
preference. A saved selection displays `GB –` when the reading is missing or unknown; a real zero
displays `GB 0%` in used mode. Lane percentages are tagged `T` (Total), `C` (Cursor), and `TP` (Third Party);
menus and VoiceOver keep the full names. Auto % ranks usable allowances, including Grok Bot, by depletion
forecast and then used percentage; an exhausted total or exhaustion of every subquota still takes priority.
Balance tokens remain independent, and the dropdown keeps its existing reset countdown and paid-weekly pace display.

Named-extra selections are stored in V4 layout keys. A V3 projection omits them while preserving explicit
reset-window selections for 0.60.x; V2/V1 projections remain available for older releases. An unchanged
downgrade preserves the full layout on return, while edits made in an older release take precedence.

## Key files
- `Sources/CodexBarCore/Providers/Cursor/CursorAppAuth.swift`
- `Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe.swift`
- `Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe+UsageSummary.swift` (summary projection)
- `Sources/CodexBarCore/Providers/Cursor/CursorTeamSpend.swift` (verified member budget)
- `Sources/CodexBarCore/Providers/Cursor/CursorSandUsage.swift` (Grok Bot weekly included usage)
- `Sources/CodexBar/Providers/Cursor/CursorLoginRunner.swift` (login flow)
- `Sources/CodexBar/Providers/Cursor/CursorLoginFlow.swift` (menu integration)
- `Sources/CodexBar/Providers/Cursor/CursorLoginBrowserRouter.swift` (browser routing and selection)

### Enterprise and Business member budgets

For team plans with a fresh nonempty email from `/api/auth/me`, the usage probe also checks `/api/dashboard/teams` and
`/api/dashboard/get-team-spend`. It prefers `portal-selected-team-id` over `team_id`,
verifies the selection against the authenticated account's teams, and uses a sole
team when no selection cookie is present (including Cursor.app authentication).
Multiple teams without a selection remain on the usage-summary fallback.

The authenticated member's `overallSpendCents` and `effectivePerUserLimitDollars`
(or `monthlyLimitDollars` when the effective limit is absent) drive the primary
percentage and plan dollars. Missing spend or non-positive limits are not treated
as a zero-usage budget. Other members' data is not included in debug output.
The optional lookup shares a ten-second deadline and the configured request timeout, with at most twenty pages of
fifty members. It requires consistent page-count metadata, full intermediate pages, and the complete page set before accepting one
matching member. Missing completion metadata, duplicate matches, or unavailable, invalid, or incomplete responses
preserve usage-summary behavior. Billing dates and extra/on-demand charges remain sourced from usage-summary;
team response dates and other members' details are not retained. Caller cancellation still stops the fetch.

## Cost reporting period

The shared [cost reporting period](cost-reporting-periods.md) supports month-to-date in the pinned cost time zone. Cursor-metered spend and daily estimates use the same event window. Quota bars continue to follow Cursor’s billing-cycle start/end dates, which can fall mid-month.

## Unified Cursor/Grok additional spend

Unified personal memberships with `limitType: "user"` read monthly additional spend from
`GET /api/dashboard/v2/usage-status?scope=user`, using the existing Cursor session. The legacy usage summary can
report zero after account unification. A valid, available monthly response supplies `usedCents`, `limitCents`,
`periodStart`, and `resetsAt`; amounts convert from cents to USD. Separate `creditsUsedCents` consumption is not
added to additional spend. See the [affected-account response](https://github.com/steipete/CodexBar/pull/4593#issuecomment-6261700483).

The optional lookup replaces the legacy request-quota lookup for these personal memberships and has a five-second
request budget. Unavailable, failed, incomplete, malformed, or out-of-period responses retain the summary's spend,
cap, and reset. Valid zero spend remains zero. Team budgets, legacy plans, weekly Grok allowance, account identity,
and the normal refresh scheduler retain their existing behavior.
