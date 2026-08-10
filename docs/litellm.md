---
summary: "LiteLLM provider setup and usage data shape."
read_when:
  - Configuring LiteLLM usage tracking
  - Troubleshooting LiteLLM API-key usage in CodexBar
---

# LiteLLM

LiteLLM uses a virtual key plus the proxy base URL. The key reads its own identity and budget data through LiteLLM's
authenticated information endpoints.

Configure it in Settings -> Providers -> LiteLLM, or in `~/.codexbar/config.json`:

```json
{
  "id": "litellm",
  "enabled": true,
  "apiKey": "<LITELLM_API_KEY>",
  "enterpriseHost": "https://litellm.example.com"
}
```

Equivalent environment variables:

```bash
export LITELLM_API_KEY=sk-...
export LITELLM_BASE_URL=https://litellm.example.com
```

`LITELLM_BASE_URL` may include `/v1`; CodexBar strips that suffix before calling LiteLLM management endpoints.

The base URL must use HTTPS unless it names a loopback or private-network address, or a `.local` mDNS host,
and must not embed credentials because the API key is sent to it as a bearer token. Plain HTTP remains
available for self-hosted proxies on loopback, RFC 1918, link-local, and IPv6 unique-local networks. A base
URL that does not meet these rules is rejected, and the provider reports that `LITELLM_BASE_URL` is invalid
instead of fetching.

The native fetcher remains authoritative. Configured plugin origins cover HTTPS and loopback HTTP, but do not cover
the existing private-network and `.local` HTTP contract without a broader host network policy.

## Data Source

The provider calls:

1. `GET /key/info` to discover the authenticated key's `user_id` and `team_id`.
2. `GET /user/info?user_id=<user_id>` to read personal spend, budget, and teams.
3. For team-only keys without a `user_id`, `GET /team/info?team_id=<team_id>` to read team spend and budget.

All requests use `Authorization: Bearer <apiKey>`. CodexBar does not request or store a LiteLLM master key.

For user-bound keys, personal usage is shown as the primary window. If the key has a team, its exact matching team
budget is shown as the secondary window and becomes the automatic menu bar metric because that budget is enforced for
the key. Team-only keys show that team budget as their sole usage window. Spend remains visible as an API-spend row
when LiteLLM does not configure a budget.

The virtual key must be allowed to read its own `/key/info` data and the corresponding user or team information
endpoint. CodexBar validates returned user and team IDs against `/key/info` before displaying usage.

## Security

Treat LiteLLM keys as secrets. CodexBar stores configured keys only in provider config or token-account storage and
sends them only to the configured LiteLLM base URL.
