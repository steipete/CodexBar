---
summary: "Muse provider data sources: local session-log token usage and the muse login metadata."
read_when:
  - Debugging Muse usage/availability
  - Updating Muse API endpoints
  - Adjusting the Muse local identity probe
---

# Muse provider

Muse Code is Meta's terminal coding agent, backed by the Meta Model API. CodexBar reads its token usage
from the session logs the CLI writes locally, and its account identity from the metadata `muse login`
writes to disk.

## Where the numbers come from

**Token usage comes from local session logs.** Muse Code records every model turn to
`~/.local/share/muse/sessions/<YYYY>/<MM>/<DD>/<session>/session.jsonl`, so CodexBar derives the same
local token history it already builds for Claude and Codex — no network call, no credential, and no
Keychain access. `XDG_DATA_HOME` is honoured.

Counted records are `model_completed` and `automated_review_completed`. Two other record kinds also
carry a `usage` object and are deliberately excluded:

- `resource_usage_sampled` — CPU and RSS gauges, not tokens.
- `workflow_child_lifecycle` — a child workflow's rollup, whose turns are already recorded on their own.

An unrecognized kind carrying token counts downgrades coverage to partial rather than disappearing from
the totals.

### Token math

A turn totals `input_tokens + output_tokens`. Verified across 1,431 recorded events, without exception:

| Relation | Meaning |
| --- | --- |
| `reasoning_tokens` ≤ `output_tokens` | reasoning is part of output |
| `cached_tokens` ≤ `input_tokens` | cached is part of input |
| `cached_tokens` == `cache_read_tokens` | the two counters are the same value |

Adding the cache or reasoning counters would double-count badly — one sampled turn reported 41,201
cached tokens against a 41,231-token input. The `automated_review_completed` shape carries its own
`total_tokens`, which equalled `input + output` in every observed event.

Costs are not reported. The logs record tokens, not billed amounts, and Meta prices per tier.

### Scanning cost

Session trees get large: a sampled tree held 883 MB across 4,388 logs, of which only 1,235 records were
model turns. Three things keep a refresh cheap:

- Day directories outside the requested history window are skipped without opening a log.
- Lines without an `input_tokens` field are rejected before JSON parsing.
- Each file's size, modification time, and the individual turns it recorded are cached in
  `~/Library/Caches/CodexBar/cost-usage/muse-sessions-v2.json`, so an unchanged log is never reread.
  Turns are stored per event rather than pre-aggregated, so a log that repeats one already-counted
  turn still contributes its remaining unique ones.

On that tree a cold scan took 16 s and a warm scan 0.26 s, for identical totals. A scan that exhausts
its budget keeps the files it finished and reports partial coverage, so the next refresh resumes.

## Quota

CodexBar does not display a Muse quota, because there is no free way to read one.

The Meta Model API publishes no usage, billing, or account endpoint. Its documented surface is
`POST /v1/responses`, `POST /v1/chat/completions`, `POST /v1/messages`, `/v1/files`, `GET /v1/models`,
and `GET /v1/status` ([API reference](https://dev.meta.ai/docs/api-reference)); every other path tested
with a valid key returned `404`, indistinguishable from a nonexistent one.

The documented `x-ratelimit-limit-tokens`, `x-ratelimit-remaining-tokens`,
`x-ratelimit-limit-requests` and `x-ratelimit-remaining-requests` headers
([pricing and rate limits](https://dev.meta.ai/docs/pricing-rate-limits)) are real, but they ride only
on billed inference responses — `GET /v1/models` and `GET /v1/status` return none. Reading them would
mean issuing a billed completion on every refresh, which would also consume the very limit it reports.
They describe a per-minute rate limit rather than a standing budget, so they would read at or near 0%
except during a burst.

An API key is still useful: it is validated with a free `GET /v1/models` (200 versus 401).

## API key

- Environment: `META_API_KEY` (the Muse CLI honours this above its own login) or `MODEL_API_KEY` (the
  variable the Meta Model API SDKs read).
- Config file: `~/.codexbar/config.json` → `providers[].apiKey` for instance `muse`, or `tokenAccounts`.
- CLI: `printf '%s' "$META_API_KEY" | codexbar config set-api-key --provider muse --stdin`.
- Used only to validate the key; usage never depends on it.
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

- Local token usage: `Sources/CodexBarCore/Providers/Muse/MuseLocalUsageReader.swift`, `Sources/CodexBarCore/Providers/Muse/MuseLocalUsageCache.swift`
- Descriptor and strategies: `Sources/CodexBarCore/Providers/Muse/MuseProviderDescriptor.swift`
- Settings: `Sources/CodexBarCore/Providers/Muse/MuseSettingsReader.swift`, `Sources/CodexBar/Providers/Muse/MuseSettingsStore.swift`
- Local login metadata: `Sources/CodexBarCore/Providers/Muse/MuseLocalAuthReader.swift`
- Fetch: `Sources/CodexBarCore/Providers/Muse/MuseUsageFetcher.swift`, `Sources/CodexBarCore/Providers/Muse/MuseUsageSnapshot.swift`
- Implementation: `Sources/CodexBar/Providers/Muse/MuseProviderImplementation.swift`
- Icon: `Sources/CodexBar/Resources/ProviderIcon-muse.svg`
- Tests: `Tests/CodexBarTests/MuseProviderTests.swift`, `Tests/CodexBarTests/MuseLocalUsageReaderTests.swift`
