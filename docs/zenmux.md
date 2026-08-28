---
summary: "ZenMux provider: Management API key setup, rolling quota windows, and PAYG balance."
read_when:
  - Configuring ZenMux usage
  - Debugging ZenMux Management API requests
---

# ZenMux Provider

CodexBar reads subscription quota windows and pay-as-you-go balance from ZenMux's documented Management API.

> **Service maturity:** ZenMux says its upstream access comes from
> [official providers or authorized cloud partners](https://zenmux.ai/), but that authorization is currently
> self-asserted by the operator. This is a young service; users and maintainers should continue to monitor its
> authorization and operating track record.

## Authentication

Create a Management API key in the [ZenMux Management Console](https://zenmux.ai/platform/management), then add it in
CodexBar Settings → Providers → ZenMux. Standard ZenMux inference API keys are not accepted by these endpoints.

You can also set the environment variable:

```bash
export ZENMUX_MANAGEMENT_API_KEY="..."
```

Or configure it through the CLI:

```bash
printf '%s' "$ZENMUX_MANAGEMENT_API_KEY" | codexbar config set-api-key --provider zenmux --stdin
```

## Data Source

CodexBar requests:

- `GET https://zenmux.ai/api/v1/management/subscription/detail`
- `GET https://zenmux.ai/api/v1/management/payg/balance` as best-effort credit enrichment

Both requests use `Authorization: Bearer <ZENMUX_MANAGEMENT_API_KEY>`. CodexBar does not read ZenMux browser cookies,
dashboard sessions, request logs, or inference prompts.

## Display

The primary meter shows the rolling five-hour quota. The secondary meter shows the rolling seven-day quota. Both show
the exact flow count and use reset timestamps returned by ZenMux. The menu also shows the subscription tier,
non-healthy account status, plan expiry, and PAYG balance in US dollars when available.

## CLI Usage

```bash
codexbar --provider zenmux
```

## Troubleshooting

- Confirm the key was created under ZenMux Management rather than the normal API-key page.
- A `401` or `403` means ZenMux rejected the Management API key.
- A PAYG-balance failure does not suppress otherwise valid subscription quota data.

## Sources

- [Get Subscription Detail](https://docs.zenmux.ai/api/platform/subscription-detail)
- [Get PAYG Balance](https://docs.zenmux.ai/api/platform/payg-balance)
