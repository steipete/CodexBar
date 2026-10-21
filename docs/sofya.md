---
summary: "Sofya account credits and monthly reset through its read-only account API."
provider_id: sofya
provider_name: Sofya
provider_source: API key for separate account plan and purchased credit balances, eligibility, and the reported monthly reset.
plugin_scope: Fixed-origin bearer GET for separate account credit pools, free-tier eligibility, and the supplied monthly reset on both engines.
read_when:
  - Setting up or modifying the Sofya provider
---

# Sofya

Enable **Sofya** in Settings → Providers and enter a Sofya API key, or set `SOFYA_API_KEY`
for the CLI. Settings saves the key in CodexBar's local config file; configured keys take
precedence over the environment. Auto and API modes use the bundled TypeScript plugin:

```sh
codexbar usage --provider sofya --source api
```

The plugin reads `GET https://sofya.co/v1/auth/me` with bearer authentication. It displays
the supplied account-wide available credits, plan credits, and purchased credits separately.
Free-tier eligibility comes from `is_free_tier`; eligible accounts also display the supplied
`credits_reset_at` timestamp in UTC. Pay-as-you-go accounts are labeled separately and do not
show a monthly reset. Missing or null balances and reset dates remain unavailable rather than
becoming zero. A response must contain at least one valid balance.

Sofya grants recurring credits to eligible GitHub accounts; email sign-ups begin on pay as
you go with zero credits. Free credits refresh monthly without rollover, while purchased
credits never expire and are spent after free credits. The endpoint does not supply an
account allowance denominator, so CodexBar does not invent a percentage bar, monthly used
amount, dollar balance, or reset date from pricing defaults. A zero balance remains visible.

Only the declared Sofya HTTPS origin receives the key. The plugin does not run searches,
import cookies, create keys, read agent files, or start login flows. Response secrets and
identity fields are ignored, and error messages never include raw response bodies. Malformed
supplied fields fail the refresh. No real-account verification was performed.

Public contract: [Sofya account API](https://sofya.co/docs) and
[credit eligibility and billing](https://sofya.co/pricing), checked October 8, 2026.
The monochrome icon uses the silhouette of Sofya's [public favicon](https://sofya.co/static/favicon.svg).
Synthetic fixtures exercise both supported plugin engines in `SofyaPluginTests`.
