---
summary: "Chutes provider: API key setup, subscription usage, and quota windows."
read_when:
  - Configuring Chutes usage
  - Debugging Chutes subscription or quota requests
---

# Chutes Provider

CodexBar reads subscription and quota usage from Chutes' management API with a manually configured API key.

## Service context

Chutes' [terms are governed by the laws of Nevis, Saint Kitts and Nevis](https://chutes.ai/terms), and its
[decentralized backend uses independent miners](https://chutes.ai/docs/miner-resources/overview). Its pricing surface
has changed over time and should be treated as historically unstable; check the [current pricing page](https://chutes.ai/pricing)
before relying on a plan or rate.

## Authentication

Create a Chutes API key using the [official authentication guide](https://chutes.ai/docs/getting-started/authentication), then add it in CodexBar Settings → Providers → Chutes.

You can also set the environment variable:

```bash
export CHUTES_API_KEY="cpk_..."
```

Or configure it through the CLI:

```bash
printf '%s' "$CHUTES_API_KEY" | codexbar config set-api-key --provider chutes --stdin
```

## Data Source

CodexBar requests:

- `GET https://api.chutes.ai/users/me/subscription_usage`
- `GET https://api.chutes.ai/users/me/quotas` when subscription data does not contain every usage window
- `GET https://api.chutes.ai/users/me/quota_usage/{chute_id}` for quota details when available

All requests use `Authorization: Bearer cpk_...`. Subscription usage is required; quota-detail requests are best-effort.

## Display

The provider prefers the rolling four-hour window as the primary meter and monthly subscription usage as the secondary meter. Accounts without a subscription can still show available pay-as-you-go quota data.

## CLI Usage

```bash
codexbar --provider chutes
```

## Troubleshooting

- Confirm the key can read `https://api.chutes.ai/users/me/subscription_usage`.
- A `401` or `403` means Chutes rejected the key.
- `CHUTES_API_URL` can override the management API base URL, but CodexBar accepts HTTPS endpoints only.
