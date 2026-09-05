---
summary: "Meta Muse Model API data sources, API key handling, and balance validation."
read_when:
  - Adding or tweaking Muse API parsing
  - Updating Muse API key handling
  - Documenting Muse provider behavior
---

# Muse (Meta) provider

Muse is Meta's Muse Spark API (https://api.meta.ai) + dev.meta.ai Team usage dashboard. CodexBar shows **API key validity, token usage, and balance** via two sources that match the CodexBar host-API pattern (apiToken + web).

CodexBar probes **web first, then API**: `web` imports dev.meta.ai session cookies (Auto/Manual) for the Team usage dashboard (`https://dev.meta.ai/usage` — total tokens, daily Token usage / Requests charts, by-model breakdown); `api` validates the Bearer key at `https://api.meta.ai/v1/models` and probes billing endpoints for balance. If web has no session or the dashboard shape hasn't been reverse-engineered yet (capture a HAR for the Team usage XHR), it falls back to `API key valid · N models available` so the tile never goes stale.

## Rationale

Meta's Muse Spark 1.1 is priced at $1.25 / $4.25 per 1M input/output tokens via the Meta Model API (https://ai.developer.meta.com/docs). Direct Meta API usage is not visible via OpenRouter/LiteLLM aggregators — use the native Muse provider for direct key tracking, and keep the OpenRouter provider for proxy spend.

## Data sources

1. **API key** — stored in `~/.codexbar/config.json` or `~/.config/codexbar/config.json`, or via `MUSE_API_KEY` / `META_API_KEY` / `META_MUSE_API_KEY` env. Required for `api` source.
2. **Base URL** (optional) — default `https://api.meta.ai`. Override via Settings → Providers → Muse → API base URL or `MUSE_API_URL` for proxies.
3. **Team usage (web, auto)** — `dev.meta.ai/usage` via browser cookies. Settings → Providers → Muse → Team usage: `Auto` imports a Google Chrome or Brave Browser session for `dev.meta.ai`; `Manual` pastes a `Cookie` header from DevTools → Network → usage XHR; `Off` disables browser-session access for API-only use. Shows total tokens (input/output) and daily Token usage / Requests when the dashboard XHR is captured. Falls back to API when no session.
4. **Validation + balance endpoints (api, probed in order)**:
   - `GET /v1/billing/usage`, `/v1/me/balance`, `/v1/billing/subscription`, `/v1/credits` — balance if present (supports `available_balance`, `balance`, `data.balance`, string or number).
   - `GET /v1/models` — fallback probe that proves key validity and counts models. Returns `API key valid` when billing is unavailable.
   - All `api` requests use `Authorization: Bearer <key>` + `Accept: application/json`, 15s timeout. 404 tries next; 401/403 surfaces as invalid key.

## Usage details

- **Web (Team usage):** when dev.meta.ai session is present, menu card shows `Team usage: N tokens` (total) and, once the XHR shape is finalized via HAR, daily windows + Requests. Until then it degrades gracefully to the API tile.
- **API:** menu card shows `Balance: $X.XX` when balance is returned, otherwise `API key valid · N models`.
- No session/weekly quota window on the Model API — pay-as-you-go; rate-limit headers are not yet exposed. Snapshot is `balanceOnly` (identity-only) so the plugin contract stays compatible. Web daily charts will emit real windows once the XHR is captured.
- Custom base URL allows self-hosted gateways (e.g., LiteLLM proxying `api.meta.ai`) while still getting CodexBar visibility.

## Key files

- `Sources/CodexBarCore/Providers/Muse/MuseProviderDescriptor.swift` (descriptor + `MuseAPIFetchStrategy` + `MuseWebFetchStrategy` pipeline `web+api`)
- `Sources/CodexBarCore/Providers/Muse/MuseUsageFetcher.swift` (API-key HTTP + flexible JSON parser)
- `Sources/CodexBarCore/Providers/Muse/MuseWebUsageFetcher.swift` (dev.meta.ai Team usage via browser cookies — probes `/api/usage*` + HTML, graceful fallback)
- `Sources/CodexBarCore/Providers/Muse/MuseSettingsReader.swift` (env var resolution)
- `Sources/CodexBarCore/Providers/Muse/MuseProviderSettings.swift` (settings section — baseURL + cookieSource)
- `Sources/CodexBar/Providers/Muse/MuseProviderImplementation.swift` (settings pickers/fields + activation)
- `Sources/CodexBar/Providers/Muse/MuseSettingsStore.swift` (SettingsStore extension — token + baseURL + cookie source/header)
- `Sources/CodexBar/Resources/ProviderIcon-muse.svg` (icon)

## CLI

```bash
# Store key
printf '%s' "$MUSE_API_KEY" | codexbar config set-api-key --provider muse --stdin

# Check usage — auto tries web then API, falls back gracefully
codexbar usage --provider muse --format json --pretty --verbose
codexbar usage --provider muse --source web  --format json --pretty  # dev.meta.ai cookies
codexbar usage --provider muse --source api  --format json --pretty  # Bearer probe
```
