---
summary: "MiniMax provider data sources: Coding Plan tokens, browser cookies, and web-session parsing."
read_when:
  - Debugging MiniMax usage parsing
  - Updating MiniMax cookie handling or coding plan scraping
  - Adjusting MiniMax provider UI/menu behavior
---

# MiniMax provider

MiniMax supports Coding Plan API tokens or web sessions. Web-session mode uses MiniMax browser/session state and
falls back across the provider's supported web requests when needed.

## Data sources

1) **Coding Plan API token**
   - Set in Preferences → Providers → MiniMax (stored in `~/.codexbar/config.json`), `MINIMAX_CODING_API_KEY`,
     or `MINIMAX_API_KEY`.
   - When both environment variables are present, `MINIMAX_CODING_API_KEY` wins so a standard `sk-api-*` key does
     not mask a coding-plan `sk-cp-*` key.
   - Auto mode can fall back to the web/cookie path when API-token credentials are rejected or the global endpoint
     returns 404.

2) **Cached/imported browser session** (automatic web path)
   - Uses CodexBar's standard cookie cache and browser import flow.

3) **Browser cookie import** (automatic)
   - Uses provider metadata for browser order and MiniMax domain filters.
   - Chromium browser storage can supplement imported cookies with access-token context when available.

4) **Manual session cookie header** (optional web-path override)
   - Stored in `~/.codexbar/config.json` via Preferences → Providers → MiniMax (Cookie source → Manual).
   - Accepts a raw `Cookie:` header or a full "Copy as cURL" string.
   - Low-level no-settings runtime can read `MINIMAX_COOKIE` or `MINIMAX_COOKIE_HEADER`.

## Requests
- Web sessions use the global host or China mainland host.
- Region picker in Providers settings toggles the host; environment overrides:
  - `MINIMAX_HOST=platform.minimaxi.com`
  - `MINIMAX_CODING_PLAN_URL=...` (full URL override)
  - `MINIMAX_REMAINS_URL=...` (full URL override)

## Cookie capture (optional override)
- Open the Coding Plan page and DevTools → Network.
- Select the request to `/v1/api/openplatform/coding_plan/remains`.
- Copy the `Cookie` request header (or use “Copy as cURL” and paste the whole line).
- Paste into Preferences → Providers → MiniMax only if automatic import fails.

## Snapshot mapping
- Primary usage, reset timing, and plan/tier are derived from Coding Plan response fields or page text.

## Key files
- `Sources/CodexBarCore/Providers/MiniMax/MiniMaxUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/MiniMax/MiniMaxProviderDescriptor.swift`
- `Sources/CodexBar/Providers/MiniMax/MiniMaxProviderImplementation.swift`
