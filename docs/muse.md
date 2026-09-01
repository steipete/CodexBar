---
summary: "Muse provider data sources: Meta Model API rate-limit headers and the local muse login metadata."
read_when:
  - Debugging Muse usage/availability
  - Updating Muse API endpoints
  - Adjusting the Muse local identity probe
---

# Muse provider

Muse Code is Meta's terminal coding agent, backed by the Meta Model API. CodexBar reads its quota from
the rate-limit headers the Model API documents, and its account identity from the metadata `muse login`
writes to disk.

## Where the numbers come from

The Meta Model API publishes **no usage, billing, credits, or account endpoint**. The documented
surface is `POST /v1/responses`, `POST /v1/chat/completions`, `POST /v1/messages`, `/v1/files`,
`GET /v1/models`, and `GET /v1/status`
([API reference](https://dev.meta.ai/docs/api-reference)).

What it does document is a set of rate-limit response headers returned with successful responses
([pricing and rate limits](https://dev.meta.ai/docs/pricing-rate-limits)):

| Header | Window |
| --- | --- |
| `x-ratelimit-limit-tokens` / `x-ratelimit-remaining-tokens` | Tokens per minute, per team |
| `x-ratelimit-limit-requests` / `x-ratelimit-remaining-requests` | Requests per minute, per team |

CodexBar therefore issues one `GET {baseURL}/models` — the cheapest documented read-only call, so a
refresh never spends tokens — and derives both windows from its response headers. Limits apply per
team, not per key.

## Data sources + selection order

- **Auto**: API when a key is present, otherwise the local login for identity only.
- **API**: `META_API_KEY` or `MODEL_API_KEY` from the environment, a token account, or the key stored
  in `~/.codexbar/config.json`. This is the only source that can report quota.
- **CLI**: `~/.config/muse/auth.json`, written by `muse login` / `muse auth set`. Supplies the account
  email and login method. It cannot report quota, because the rate-limit headers only accompany an
  authenticated API request.

Muse exposes no non-interactive auth-status command — `muse auth` offers only `auth set` — so login
state is read from that file rather than inferred from a CLI exit code. Only the plaintext metadata is
parsed; the credential itself stays in the Keychain and is never read, so refreshing Muse never raises
a Keychain prompt.

## API key

- Environment: `META_API_KEY` (the Muse CLI honours this above its own login) or `MODEL_API_KEY` (the
  variable the Meta Model API SDKs read).
- Config file: `~/.codexbar/config.json` → `providers[].apiKey` for instance `muse`, or `tokenAccounts`.
- CLI: `printf '%s' "$META_API_KEY" | codexbar config set-api-key --provider muse --stdin`.
- Base URL override: `MUSE_BASE_URL`. The key is sent to this host as a bearer token, so the override is
  validated like every other provider endpoint — HTTPS anywhere, HTTP only for loopback and
  private-network gateways, never with embedded credentials. An override that fails validation surfaces
  an error; it never silently falls back to `api.meta.ai`. With no override, the base URL recorded by
  `muse login` is used, then `https://api.meta.ai/v1`.

## Errors

- `401`/`403` → invalid API key.
- Any other non-2xx, or a transport failure → a visible error. A failed refresh is never presented as a
  configured-and-healthy provider.
- A `200` without rate-limit headers → identity only, with no invented usage window. The credential is
  known good because the request succeeded.

## Key files

- Descriptor and strategies: `Sources/CodexBarCore/Providers/Muse/MuseProviderDescriptor.swift`
- Settings: `Sources/CodexBarCore/Providers/Muse/MuseSettingsReader.swift`, `Sources/CodexBar/Providers/Muse/MuseSettingsStore.swift`
- Local login metadata: `Sources/CodexBarCore/Providers/Muse/MuseLocalAuthReader.swift`
- Fetch: `Sources/CodexBarCore/Providers/Muse/MuseUsageFetcher.swift`, `Sources/CodexBarCore/Providers/Muse/MuseUsageSnapshot.swift`
- Implementation: `Sources/CodexBar/Providers/Muse/MuseProviderImplementation.swift`
- Icon: `Sources/CodexBar/Resources/ProviderIcon-muse.svg`
- Tests: `Tests/CodexBarTests/MuseProviderTests.swift`
