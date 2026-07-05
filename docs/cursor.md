---
summary: "Cursor provider data sources: browser cookies or stored session; usage + billing via cursor.com APIs."
read_when:
  - Debugging Cursor usage parsing
  - Updating Cursor cookie import or session storage
  - Adjusting Cursor provider UI/menu behavior
---

# Cursor provider

Cursor is primarily web-backed. Usage is fetched via browser cookies or a stored WebKit session, with Cursor.app local auth as a final fallback.

## Data sources + fallback order

1) **Cached cookie header** (preferred)
   - Stored after successful browser import.
   - Keychain cache: `com.steipete.codexbar.cache` (account `cookie.cursor`).

2) **Browser cookie import**
   - Cookie order from provider metadata (default: Safari → Chrome → Firefox).
   - Domain filters: `cursor.com`, `cursor.sh`.
   - Cookie names required (any one counts):
     - `WorkosCursorSessionToken`
     - `__Secure-next-auth.session-token`
     - `next-auth.session-token`

3) **Stored session cookies** (fallback)
   - Captured by the "Add Account" WebKit login flow.
   - Login teardown uses `WebKitTeardown` to avoid Intel WebKit crashes.
   - Stored at: `~/Library/Application Support/CodexBar/cursor-session.json`.

4) **Cursor.app local auth** (last fallback)
   - Reads Cursor.app's VS Code-style global state DB for the local app bearer token.
   - File:
     - macOS: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
     - Linux: `$XDG_CONFIG_HOME/Cursor/User/globalStorage/state.vscdb` (default `~/.config/Cursor/...`)
   - Used only after cookie/session sources fail so existing account-selection precedence stays stable.
   - On Linux, this is the primary automatic source because browser import and the WebKit login flow are macOS-only.
   - Derives Cursor's first-party web-session cookie, then uses the same usage and account endpoints as browser sessions.
   - Account identity comes from that authenticated session; cached app profile fields are not mixed across accounts.

Manual option:
- Preferences → Providers → Cursor → Cookie source → Manual.
- Paste the `Cookie:` header from a cursor.com request.

## API endpoints
- `GET https://cursor.com/api/usage-summary`
  - Plan usage (included), on-demand usage, billing cycle window.
- `GET https://cursor.com/api/auth/me`
  - User email + name.
- `GET https://cursor.com/api/usage?user=ID`
  - Legacy request-based plan usage (request counts + limits).

## Cookie file paths
- Safari: `~/Library/Cookies/Cookies.binarycookies`
- Chrome/Chromium forks: `~/Library/Application Support/Google/Chrome/*/Cookies`
- Firefox: `~/Library/Application Support/Firefox/Profiles/*/cookies.sqlite`

## Linux CLI
- `codexbar usage --provider cursor` reads the signed-in Cursor app's access token from the Linux global state DB and reuses the same `cursor.com` usage endpoints as macOS.
- Automatic browser cookie import and the in-app WebKit login flow remain macOS-only.
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

## Snapshot mapping
- Primary: plan usage percent (included plan).
- Secondary: Auto + Composer usage percent.
- Tertiary: API (named model) usage percent.
- Provider cost: Extra usage USD. A capped individual budget wins; team accounts without a user cap use the shared team on-demand budget.
- Reset: billing cycle end date.

## Key files
- `Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe.swift`
- `Sources/CodexBar/CursorLoginRunner.swift` (login flow)
