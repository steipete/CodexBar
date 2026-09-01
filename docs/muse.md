---
summary: "Muse provider data sources: Meta API key (META_API_KEY) and CLI probe."
read_when:
  - Debugging Muse usage/availability
  - Updating Muse API endpoints
  - Adjusting Muse CLI probe
---

# Muse provider

Muse (Meta's terminal coding agent) is supported via API key or local CLI detection. Usage quotas are probed via the Meta API when available; until Meta publishes a stable usage endpoint, the provider shows API key / CLI authentication status.

## Data sources + selection order

- **Auto** (default): API (`META_API_KEY` / `MUSE_API_KEY` / token account) → CLI (`muse` binary).
- **API**: `META_API_KEY` or `MUSE_API_KEY` from environment, or a token account stored in `~/.codexbar/config.json`.
- **CLI**: local `muse` binary (`~/.local/bin/muse`, Homebrew, `/usr/local/bin/muse`, or `MUSE_CLI_PATH` override). Reports `muse --version` and checks `muse auth --help` reachability.

Manual account tokens: add entries to `~/.codexbar/config.json` (`tokenAccounts`) with Muse API keys. Each account appears as a separate card when selected.

## API key

- Environment: `META_API_KEY` (preferred), `MUSE_API_KEY` (fallback).
- Config file: `~/.codexbar/config.json` → `providers[].apiKey` for instance `muse`, or `tokenAccounts`.
- CLI/env: `printf '%s' "$META_API_KEY" | codexbar config set-api-key --provider muse --stdin`.
- Base URL override: `MUSE_BASE_URL` (default `https://api.meta.ai/v1`).

## CLI

- Binary: `muse` (`muse --version` for version, `muse auth --help` for auth probe).
- Override: `MUSE_CLI_PATH`.
- Well-known paths: `~/.local/bin/muse`, `/opt/homebrew/bin/muse`, `/usr/local/bin/muse`.
- `muse login` stores credentials in macOS Keychain (`ai.meta.dev.credentials`, account `meta`). `META_API_KEY` always takes priority over the Keychain login.

## Endpoints probed (API mode)

When an API key is present, CodexBar probes candidate usage endpoints with `Authorization: Bearer <key>`:

- `{baseURL}/usage`
- `{baseURL}/billing/usage`
- `{baseURL}/me`
- `https://api.meta.ai/v1/usage`

`200` responses are parsed as flexible JSON (`session`/`weekly` windows, `used_percent`/`limit`/`remaining_percent`, `email`/`plan`). `401`/`403` surface as invalid-key, `404`/`501` fall back to the next candidate. If no endpoint responds with usable data, the menu shows an identity-only card ("API Key") so the provider is visibly configured while the quota fetch remains best-effort.

## Key files

- Descriptor: `Sources/CodexBarCore/Providers/Muse/MuseProviderDescriptor.swift`
- Settings: `Sources/CodexBarCore/Providers/Muse/MuseSettingsReader.swift`, `Sources/CodexBar/Providers/Muse/MuseSettingsStore.swift`
- Fetch: `Sources/CodexBarCore/Providers/Muse/MuseUsageFetcher.swift`, `Sources/CodexBarCore/Providers/Muse/MuseUsageSnapshot.swift`
- Implementation: `Sources/CodexBar/Providers/Muse/MuseProviderImplementation.swift`
- Icon: `Sources/CodexBar/Resources/ProviderIcon-muse.svg`
