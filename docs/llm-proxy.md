---
summary: "LLM Proxy provider setup and quota-stats usage source."
read_when:
  - Configuring LLM Proxy usage tracking
  - Debugging aggregate proxy quota or provider breakdown display
---

# LLM Proxy

CodexBar reads aggregate usage from an LLM-API-Key-Proxy compatible `/v1/quota-stats` endpoint.

## Setup

Store the API key:

```bash
printf '%s' "$LLM_PROXY_API_KEY" | codexbar config set-api-key --provider llmproxy --stdin
```

Set the base URL with `LLM_PROXY_BASE_URL`, or add `enterpriseHost` to the provider config:

```json
{
  "id": "llmproxy",
  "enabled": true,
  "apiKey": "<REDACTED>",
  "enterpriseHost": "https://proxy.example.com"
}
```

The base URL may point at either the service root or `/v1`; CodexBar normalizes both to `/v1/quota-stats`.

The base URL must use HTTPS unless it names a loopback or private-network address, or a `.local` mDNS host,
and must not embed credentials because the API key is sent to it as a bearer token. Plain HTTP remains
available for self-hosted proxies on loopback, RFC 1918, link-local, and IPv6 unique-local networks. A base
URL that does not meet these rules is rejected, and the provider reports that `LLM_PROXY_BASE_URL` is invalid
instead of fetching.

The native fetcher remains authoritative. Configured plugin origins cover HTTPS and loopback HTTP, but do not cover
the existing private-network and `.local` HTTP contract without a broader host network policy.

## Menu display

- Primary: lowest remaining quota group, rendered as percent used.
- Secondary: total requests.
- Tertiary: total tokens.
- Extra rows: top provider summaries by request count.
- Cost: approximate spend when the proxy reports `approx_cost`.

`quota_groups` may be either an array or a keyed object; CodexBar accepts both shapes.
