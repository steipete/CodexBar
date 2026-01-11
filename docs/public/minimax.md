---
summary: "MiniMax provider data sources: browser cookies + coding plan remains API."
read_when:
  - Debugging MiniMax usage parsing
  - Updating MiniMax cookie handling or coding plan scraping
  - Adjusting MiniMax provider UI/menu behavior
---

# MiniMax provider

MiniMax is web-only. Usage is fetched from the Coding Plan remains API using a session cookie header.

## Data sources + fallback order

1) **Browser cookie import** (automatic)
   - Cookie order from provider metadata (default: Safari → Chrome → Firefox).
   - Merges Chromium profile cookies across the primary + Network stores before attempting a request.
   - Tries each browser source until the Coding Plan API accepts the cookies.
   - Domain filters: `platform.minimax.io`, `minimax.io`.

2) **Browser local storage access token** (Chromium-based)
   - Reads `access_token` (and related tokens) from Chromium local storage (LevelDB) to authorize the remains API.
   - If decoding fails, falls back to a text-entry scan for `minimax.io` keys/values and filters for MiniMax JWT claims.
   - Used automatically; no UI field.
   - Also extracts `GroupId` when present (appends query param).

3) **Manual session cookie header** (optional override)
   - Stored in Keychain via Preferences → Providers → MiniMax (Cookie source → Manual).
   - Accepts a raw `Cookie:` header or a full "Copy as cURL" string.
   - When a cURL string is pasted, MiniMax extracts the cookie header plus `Authorization: Bearer …` and
     `GroupId=…` for the remains API.
   - CLI/runtime env: `MINIMAX_COOKIE` or `MINIMAX_COOKIE_HEADER`.

## Endpoints
- `GET https://platform.minimax.io/user-center/payment/coding-plan`
  - HTML parse for "Available usage" and plan name.
- `GET https://platform.minimax.io/v1/api/openplatform/coding_plan/remains`
  - Fallback when HTML parsing fails.
  - Sent with a `Referer` to the Coding Plan page.
  - Adds `Authorization: Bearer <access_token>` when available.
  - Adds `GroupId` query param when known.

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

## Key files
- `Sources/CodexBarCore/Providers/MiniMax/MiniMaxUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/MiniMax/MiniMaxProviderDescriptor.swift`
- `Sources/CodexBar/Providers/MiniMax/MiniMaxProviderImplementation.swift`
