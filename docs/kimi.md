---
summary: "Kimi Code provider notes: official CLI OAuth, optional API key, and /usages parsing."
read_when:
  - Adding or modifying the Kimi provider
  - Debugging Kimi Code auth or usage parsing
  - Adjusting Kimi settings or labels
---

# Kimi Code provider

Tracks usage for [Kimi Code](https://www.kimi.com/code/) in CodexBar.

This is a hard cutover from the older cookie-based `www.kimi.com/code` integration. The provider now targets the
official Kimi Code product and its `api.kimi.com/coding/v1` usage endpoint.

## Features

- Displays Kimi Code weekly quota usage
- Shows rolling rate-limit windows returned by the Kimi Code API
- Uses the official Kimi CLI OAuth session when available
- Supports an optional API key override for third-party coding-agent setups

## Data sources

CodexBar supports two Kimi Code auth paths:

1. **Kimi CLI OAuth**
   - Reads `~/.kimi/credentials/kimi-code.json`
   - Refreshes expired access tokens through `https://auth.kimi.com/api/oauth/token`
   - This is the preferred source in `Auto` mode
2. **API key**
   - Stored in `~/.codexbar/config.json`
   - Or supplied via `KIMI_CODE_API_KEY` / `KIMI_API_KEY`

## Usage endpoint

- `GET https://api.kimi.com/coding/v1/usages`
- `Authorization: Bearer <token>`

The payload contains:

- top-level `usage` for the primary weekly quota row
- `limits[]` for rolling limit rows such as the 5-hour quota

CodexBar maps the summary row to the primary usage lane and the first two limit rows to secondary and tertiary lanes.

## Settings

Preferences → Providers → Kimi exposes:

- **Usage source**
  - `Auto`: prefer Kimi CLI OAuth, then fall back to API key
  - `CLI OAuth`: only use `~/.kimi/credentials/kimi-code.json`
  - `API Key`: only use the configured key
- **API key**
  - Optional unless you want explicit API-key mode or a fallback when the CLI is not signed in

## Related files

- `Sources/CodexBarCore/Providers/Kimi/KimiProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Kimi/KimiOAuthCredentials.swift`
- `Sources/CodexBarCore/Providers/Kimi/KimiUsageFetcher.swift`
- `Sources/CodexBar/Providers/Kimi/KimiProviderImplementation.swift`
- `Tests/CodexBarTests/KimiProviderTests.swift`
