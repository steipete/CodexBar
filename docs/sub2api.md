---
summary: "sub2api setup for group API-key quota, subscription usage, and wallet balance."
read_when:
  - Configuring sub2api usage tracking
  - Monitoring multiple sub2api groups
  - Troubleshooting the sub2api /v1/usage integration
---

# sub2api

CodexBar reads the accounting data exposed by a sub2api group API key. It calls only `GET /v1/usage`; it does not
send model requests, read prompts, or require a dashboard JWT.

> **Upstream terms:** sub2api is a self-hosted subscription-to-API gateway, and [its own README warns that using it
> may violate upstream provider terms](https://github.com/Wei-Shaw/sub2api#readme). CodexBar only reads usage from
> the user's own deployment and does not endorse or validate that access pattern.

## Setup

Configure the deployment URL in Settings → Providers → sub2api. The URL must use HTTPS, except for loopback HTTP
such as `http://127.0.0.1:8080` during local development.

For one group, paste its key into the fallback API key field or configure environment variables:

```bash
export SUB2API_BASE_URL=https://sub2api.example.com
export SUB2API_API_KEY=sk-...
```

For multiple groups, create one key per group in sub2api, then add each key under **Group API keys** with a descriptive
label such as `Claude`, `Codex`, or `Gemini`. CodexBar's account switcher selects the active key; stacked account mode
can fetch and display several group keys at once.

## Display

The response mode determines what CodexBar shows:

- Quota-limited key: total quota plus optional 5-hour, daily, and 7-day rate-limit windows.
- Subscription group: daily, weekly, and monthly spend against configured limits, plus expiration.
- Wallet group: current wallet balance.
- All modes: today and total key-scoped requests, tokens, and actual cost when sub2api returns them.

Usage totals are scoped to the authenticated key. Wallet balance is scoped to the owning user, so CodexBar keeps it
on each account card and does not sum it across keys.

For subscription groups, CodexBar displays the daily, weekly, and monthly counters returned by `/v1/usage`. These
windows follow the subscription's billing anchors; the endpoint does not expose enough boundary information to
reconstruct them safely from the key-scoped calendar-day series. If several keys share one group, the subscription
counters can therefore be shared even though the request and cost totals remain key-scoped.

## Security

Keys are stored using CodexBar's existing provider config or token-account storage. CodexBar sends a key only to the
validated base URL using `Authorization: Bearer <key>`.
