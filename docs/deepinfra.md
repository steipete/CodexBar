---
summary: "DeepInfra provider setup, API-key billing queries, and balance/spend display."
read_when:
  - Adding or modifying the DeepInfra provider
  - Debugging DeepInfra API-key billing fetches
  - Explaining DeepInfra setup or balance display
---

# DeepInfra provider

DeepInfra is API-only. CodexBar uses DeepInfra's documented billing endpoints and does not send model prompts or account data to any other service.

## Setup

1. Create an API key in the [DeepInfra dashboard](https://deepinfra.com/dash).
2. In CodexBar, open **Settings > Providers > DeepInfra > API tokens** and add the key.

You can instead set `DEEPINFRA_API_KEY` or `DEEPINFRA_TOKEN` in CodexBar's environment. `DEEPINFRA_API_KEY` takes precedence when both are present.

## Data source

CodexBar sends the key as a bearer token to:

- `GET https://api.deepinfra.com/payment/checklist?compute_owed=true` for prepaid balance, recent spend, spending limit, and suspension state.
- `GET https://api.deepinfra.com/payment/usage?from=current` for current-month spend.

DeepInfra represents prepaid funds as a negative `stripe_balance`; CodexBar converts that to a positive “available” amount. A positive value is shown as money owed.

## Display

- The automatic menu-bar metric shows available prepaid balance.
- The provider card shows available balance and current-month spend without inventing a percentage quota.
- If the account has a positive spending limit, CodexBar shows billing-cycle spend against that limit.
- A suspended account is shown as exhausted with DeepInfra's suspension reason when one is provided.

## Troubleshooting

- `401`: DeepInfra rejected the API key. Remove the saved token, create a new API key, and enter it without a `Bearer ` prefix.
- `403`: The key is valid but cannot access DeepInfra billing data.
- Missing provider: enable DeepInfra under **Settings > Providers** and add a token account or environment key.

CodexBar never logs the API key or raw billing response.

[DeepInfra service status](https://status.deepinfra.com)
