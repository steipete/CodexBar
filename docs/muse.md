---
summary: "Meta Muse Model API data sources, API key handling, and balance validation."
read_when:
  - Adding or tweaking Muse API parsing
  - Updating Muse API key handling
  - Documenting Muse provider behavior
---

# Muse (Meta) provider

Muse is Meta's Muse Spark API (https://api.meta.ai). CodexBar shows **API key validity and balance** where available. The provider is API-only — no browser cookies, OAuth, or CLI source.

CodexBar only needs a valid API key. If the billing endpoint exposes a balance, it is shown; otherwise the menu card shows `API key valid · N models available` from the `/v1/models` probe.

## Rationale

Meta's Muse Spark 1.1 is priced at $1.25 / $4.25 per 1M input/output tokens via the Meta Model API (https://ai.developer.meta.com/docs). Direct Meta API usage is not visible via OpenRouter/LiteLLM aggregators — use the native Muse provider for direct key tracking, and keep the OpenRouter provider for proxy spend.

## Data sources

1. **API key** stored in `~/.codexbar/config.json` or `~/.config/codexbar/config.json`, or via `MUSE_API_KEY` / `META_API_KEY` / `META_MUSE_API_KEY` env.
2. **Base URL** (optional) — default `https://api.meta.ai`. Override via Settings → Providers → Muse → API base URL or `MUSE_API_URL` for proxies.
3. **Validation + balance endpoints** (probed in order):
   - `GET /v1/billing/usage`, `/v1/me/balance`, `/v1/billing/subscription`, `/v1/credits` — balance if present (supports multiple JSON shapes: `available_balance`, `balance`, `data.balance`, string or number).
   - `GET /v1/models` — fallback probe that proves key validity and counts models. Returns `API key valid` when billing is unavailable.
   - All requests use `Authorization: Bearer <key>` + `Accept: application/json`, 15s timeout. 404 on billing paths falls through; 401/403 surfaces as invalid key.

## Usage details

- Menu card shows `Balance: $X.XX` when balance is returned, otherwise `API key valid · N models`.
- No session/weekly window — Meta API is pay-as-you-go; rate-limit headers are not yet exposed. The snapshot is represented as `balanceOnly` (identity-only) so the plugin contract remains compatible.
- Custom base URL allows self-hosted gateways (e.g., LiteLLM proxying `api.meta.ai`) while still getting CodexBar visibility.

## Key files

- `Sources/CodexBarCore/Providers/Muse/MuseProviderDescriptor.swift` (descriptor + fetch strategy)
- `Sources/CodexBarCore/Providers/Muse/MuseUsageFetcher.swift` (HTTP client + flexible JSON parser)
- `Sources/CodexBarCore/Providers/Muse/MuseSettingsReader.swift` (env var resolution)
- `Sources/CodexBarCore/Providers/Muse/MuseProviderSettings.swift` (settings section)
- `Sources/CodexBar/Providers/Muse/MuseProviderImplementation.swift` (settings field + activation)
- `Sources/CodexBar/Providers/Muse/MuseSettingsStore.swift` (SettingsStore extension)
- `Sources/CodexBar/Resources/ProviderIcon-muse.svg` (icon)

## CLI

```bash
# Store key
printf '%s' "$MUSE_API_KEY" | codexbar config set-api-key --provider muse --stdin

# Check usage (requires key)
codexbar usage --provider muse --source api --format json
codexbar usage --provider muse --verbose
```
