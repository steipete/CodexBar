---
summary: "TrustedRouter API key spend, limit, and remaining balance."
provider_id: trustedrouter
provider_name: TrustedRouter
provider_source: API key for the key's remaining limit and daily, weekly, monthly, and total spend.
plugin_scope: Fixed-origin bearer GET of the current key's microdollar limit and spend, without inferred quotas or reset dates, on both engines.
read_when:
  - Configuring TrustedRouter usage
  - Debugging TrustedRouter key responses
---

# TrustedRouter

[TrustedRouter](https://trustedrouter.com) is an OpenAI-compatible gateway at `https://api.trustedrouter.com/v1`.
Enable TrustedRouter in Settings → Providers and save an inference API key from
[API keys](https://trustedrouter.com/console/api-keys), or set `TRUSTEDROUTER_API_KEY` for the CLI. The provider is
disabled by default. The key uses CodexBar's existing local provider configuration.

The bundled plugin sends one read-only bearer-authenticated request per refresh:

```text
GET https://api.trustedrouter.com/v1/key
```

The response follows the OpenRouter `/key` shape and adds integer microdollar copies of every money field
(1 USD = 1,000,000). CodexBar reads `usage_microdollars`, `usage_daily_microdollars`,
`usage_weekly_microdollars`, `usage_monthly_microdollars`, `limit_microdollars`, and
`limit_remaining_microdollars`. Daily, weekly, and monthly spend are current UTC windows.

When the key has a spending limit, **Remaining** is the API's `limit_remaining`, which already excludes spend held for
requests still in flight; CodexBar does not subtract reservations a second time. The bar shows the spent share of the
limit. Keys without a limit show spend only. CodexBar does not infer a reset date from `limit_reset`, and does not
read the account credit balance, which requires a management key on `https://trustedrouter.com/v1/credits`.

Missing, malformed, negative, fractional, or nonfinite microdollar amounts fail instead of appearing as zero. A limit
without a remaining amount, or the reverse, also fails. HTTP failures are classified without displaying the response
body. Only `api.trustedrouter.com` is authorized for API requests. CodexBar never calls completion endpoints.

This integration was checked against the documented response shape and synthetic fixtures on both plugin engines;
it has not been verified against a live TrustedRouter account.

The monochrome icon uses the route mark from TrustedRouter's [site favicon](https://trustedrouter.com/static/favicon.svg);
the original accent is `#A9CDB9`.

## Operator and response contract

TrustedRouter is operated by Lore Hex Corp, founded by Joseph Perla, as identified on its
[About page](https://trustedrouter.com/about). The [public response serializer](https://github.com/Lore-Hex/quill-router/blob/main/src/trusted_router/serialization.py)
defines the integer microdollar fields consumed by this plugin. A reported zero-dollar key limit remains
visible as Limit and Remaining amounts, without a percentage gauge. An explicit `null` limit means unlimited;
missing monetary fields are rejected. Daily, weekly, and monthly spend follows the key's BYOK-in-limit policy;
lifetime usage is credits-only, so these values need not add up to the same total.
