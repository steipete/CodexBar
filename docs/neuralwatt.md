---
summary: "Neuralwatt provider notes: API key setup and quota usage fields."
read_when:
  - Adding or modifying the Neuralwatt provider
  - Debugging Neuralwatt API keys or quota parsing
  - Adjusting Neuralwatt credit labels
---

# Neuralwatt Provider

The Neuralwatt provider reads account quota from the Neuralwatt Cloud API using an API key.
Neuralwatt Cloud is an OpenAI-compatible inference API with energy-based pricing. Prepaid credits
are a deplete-as-you-go USD balance: they do **not** reset on a billing cycle and are refilled by
topping up. Active subscription usage is billed separately against a kWh allowance. The quota
endpoint exposes both surfaces plus current-month spend and optional per-key spending allowances.

## Features

- Active subscription kWh usage (`kwh_used` / `kwh_included`) as the primary quota window, with the
  subscription period end as its reset date.
- The separate prepaid USD credit balance as a pay-as-you-go balance. It does not reset and may be
  zero while subscription kWh remains available.
- Per-key spending allowance (`spent_usd` / `limit_usd`) as an extra rate window when configured.
- Subscription plan shown as the provider identity label, falling back to accounting method (`Token` vs `Energy`).
- Current calendar-month spend is parsed for future/reporting use, but is not shown as a resettable quota window.

## Setup

### CLI

Store the API key without opening Settings:

```bash
printf '%s' "$NEURALWATT_API_KEY" | codexbar config set-api-key --provider neuralwatt --stdin
```

This trims the piped key, writes it to CodexBar's config file (`~/.config/codexbar/config.json`
by default, or the legacy `~/.codexbar/config.json` when already present), and enables Neuralwatt by
default. Use `--no-enable` to save the key without enabling the provider.

### Settings

1. Open **Settings → Providers**
2. Enable **Neuralwatt**
3. Open `https://portal.neuralwatt.com/dashboard`
4. Create or copy an API key
5. Paste the key into CodexBar's Neuralwatt provider settings

### Environment Variables

CodexBar also accepts these environment variables:

- `NEURALWATT_API_KEY`

For tests or self-hosted/proxy setups, override the API base URL with `NEURALWATT_API_URL`.

## How It Works

- Endpoint: `GET https://api.neuralwatt.com/v1/quota`
- Auth header: `Authorization: Bearer sk-...`
- Fields used: `balance.credits_remaining_usd`, `balance.total_credits_usd`,
  `balance.credits_used_usd`, `balance.accounting_method`,
  `usage.current_month.cost_usd`,
  `subscription.plan`, `subscription.current_period_end`, `subscription.kwh_included`,
  `subscription.kwh_used`, `subscription.kwh_remaining`,
  `key.allowance.limit_usd`, `key.allowance.spent_usd`, `key.allowance.period`
- `credits_used_usd` is derived as `total_credits_usd − credits_remaining_usd` when the API omits it.
- `subscription` may be `null`; prepaid balance remains visible without a subscription window.
- Transient quota failures are retried once, including `Retry-After` handling for rate limits.

## Troubleshooting

### "Missing Neuralwatt API key"

Set the key with `codexbar config set-api-key --provider neuralwatt --stdin`, add it in
**Settings → Providers → Neuralwatt**, set `NEURALWATT_API_KEY`, or configure a Neuralwatt token
account in CodexBar.

### "Neuralwatt API error"

Confirm the API key is valid and that the current network can reach `api.neuralwatt.com`. The
quota endpoint is rate-limited to 1 request per second per customer; CodexBar refreshes on its
normal cycle so this should not be hit in practice.
