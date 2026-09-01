---
summary: "Cursor provider data sources, external-browser account switching, and cursor.com APIs."
read_when:
  - Debugging Cursor usage parsing
  - Updating Cursor cookie import or session storage
  - Adjusting Cursor provider UI/menu behavior
---

# Cursor provider

On macOS, Cursor can reuse Cursor.app's local session or a cursor.com browser session. Automatic mode prefers a usable
Cursor.app session and falls back to cookies when the app token is missing, expired, invalid, or rejected.

## Data sources + fallback order

1) **Cursor.app local auth** (preferred in Automatic mode)
   - Reads Cursor.app's VS Code-style global state DB for `ItemTable` key `cursorAuth/accessToken`.
   - BLOB decoding recognizes BOM-less ASCII UTF-16LE tokens before UTF-8, which would otherwise keep interleaved
     NUL bytes. Other encodings retain the existing UTF-8/UTF-16LE fallback; tokens are not normalized, and malformed
     nonempty values remain distinct from a missing session so they cannot enable stale cached-account fallback.
   - Files consulted by SQLite:
     - macOS main DB: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
     - Active WAL sidecars when present: `state.vscdb-wal` and `state.vscdb-shm`
   - The database is opened read-only. Active WAL state is read normally; an idle WAL-mode main file with no
     sidecars uses SQLite immutable mode so CodexBar does not recreate files in Cursor's directory.
   - The token is used only while its JWT expiry is more than 60 seconds away. CodexBar never refreshes it.
   - A validated derived session is also persisted owner-only at
     `~/Library/Application Support/CodexBar/cursor-session.json` through the standard credential-file writer.
   - When an already-cached cookie exposes a different email or subject, CodexBar logs the mismatch and keeps the
     chosen Cursor.app identity on the usage snapshot/card. It does not combine app usage with browser identity.

2) **Cached cookie header**
   - Stored after successful browser import.
   - Keychain cache: `com.steipete.codexbar.cache` (account `cookie.cursor`).

3) **Browser cookie import**
   - Cookie order from provider metadata (default: Safari → Chrome → Firefox).
   - Domain filters: `cursor.com`, `cursor.sh`.
   - Cookie names required (any one counts):
     - `WorkosCursorSessionToken`
     - `__Secure-next-auth.session-token`
     - `next-auth.session-token`

4) **Stored session cookies** (fallback)
   - Legacy sessions captured by older CodexBar releases remain readable.
   - Stored at: `~/Library/Application Support/CodexBar/cursor-session.json`.

On macOS, explicit `--source web` skips Cursor.app local auth and uses only the cookie ladder. A configured Manual cookie
header remains an explicit override. `codexbar usage --provider cursor --source auto --verbose` prints the selected
automatic path and is the quickest live-read check after Cursor login.

Manual option:
- Preferences → Providers → Cursor → Cookie source → Manual.
- Paste the `Cookie:` header from a cursor.com request.

## Add and switch account
- **Add Account** opens `https://authenticator.cursor.sh/` in a supported browser.
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
- `POST https://cursor.com/api/dashboard/get-sand-usage-status`
  - Grok Bot weekly included usage (`usagePercent`, `nextResetTimestampUtc`). Same session cookie;
    requires `Origin: https://cursor.com`. Best-effort: a failure leaves Cursor's monthly bars intact.

## Cookie file paths
- Safari: `~/Library/Cookies/Cookies.binarycookies`
- Chrome/Chromium forks: `~/Library/Application Support/Google/Chrome/*/Cookies`
- Firefox: `~/Library/Application Support/Firefox/Profiles/*/cookies.sqlite`

## Linux CLI
- Cursor.app session import, automatic browser cookie import, and the external-browser Add/Switch flow are macOS app features.
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

Two totals are reported from the same events:
- **API-rate estimate**: reported `tokenUsage.totalCents`, with an API-list-price fallback only when the field is missing or null. Fallbacks use the existing cached models.dev catalog or bundled rates at the event date, preserve Cursor's disjoint input/cache counters, and do not read native Codex custom pricing or refresh prices over the network. Reported zero remains zero; malformed, negative, nonfinite, or otherwise invalid costs stay unpriced and fail the same-model sum closed. Unknown models remain unpriced. Reported, estimated, and unpriced request counts remain visible even when a rejected cost invalidates a model total.
- **Cursor-metered** (`meteredCostUSD`): what Cursor's plan actually deducts over the window, shown as its own "Cursor-metered:" line.
- Metered-only request events remain visible even when Cursor does not include token details; cookie/config resolution failures stop the fetch instead of falling back to another session.

API-list-price estimates are not estimates of actual Cursor charges: they do not apply plan-specific Cursor Token Rates, regional adjustments, or legacy billing rules. `chargedCents` and Cursor-metered totals remain separate and unchanged. In Overview, history coverage describes the included sources' established history; a selected subscription without spend still makes amounts partial and remains disclosed in the subscription count, without erasing another source's known history days.

Caching: the app holds the snapshot for an in-memory hourly TTL, keyed by the history window plus the cookie source and resolved account (manual-cookie hash or auto-mode account fingerprint), so switching accounts or pasting a new cookie invalidates it immediately.

## Snapshot mapping
- Primary: plan usage percent (included plan).
- Secondary: Cursor (Cursor models) usage percent.
- Tertiary: Third Party usage percent.
- Extra: Grok Bot weekly included usage from `get-sand-usage-status` when the account has a non-zero Bot allowance.
- Provider cost: Extra usage USD. A capped individual budget wins; team accounts without a user cap use the shared team on-demand budget.
- Reset: billing cycle end date for monthly bars; Grok Bot uses `nextResetTimestampUtc` (weekly).

## Key files
- `Sources/CodexBarCore/Providers/Cursor/CursorAppAuth.swift`
- `Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe.swift`
- `Sources/CodexBarCore/Providers/Cursor/CursorSandUsage.swift` (Grok Bot weekly included usage)
- `Sources/CodexBar/CursorLoginRunner.swift` (login flow)
- `Sources/CodexBar/Providers/Cursor/CursorLoginFlow.swift` (menu integration)
- `Sources/CodexBar/CursorLoginBrowserRouter.swift` (browser routing and selection)
