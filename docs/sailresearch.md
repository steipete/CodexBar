---
summary: "Sail Research organization credit balance and spend through its Usage API."
provider_id: sailresearch
provider_name: Sail Research
provider_source: API key for organization credit balance and combined inference/Sailbox spend.
plugin_scope: Fixed-origin bearer GET for organization billing on both engines; fractional-cent conversion, plan-limited history, no inferred quotas or resets.
read_when:
  - Configuring Sail Research usage
  - Debugging Sail Research billing data
---

# Sail Research

Enable Sail Research in Settings → Providers and enter a Sail API key, or set `SAIL_API_KEY`.
The masked field saves the key in CodexBar's local config file; configured keys override the
environment. This is the same key used for Sail inference. See [CLI configuration](cli-configuration.md).

Auto and API use the bundled TypeScript plugin on macOS and Linux:

```sh
codexbar usage --provider sailresearch --source api
```

The plugin reads `GET https://api.sailresearch.com/v2/usage/summary?range=30d` with bearer
authentication. It shows the organization-wide net credit balance and combined inference and
Sailbox spend. The API key determines the organization; the amounts are not limited to that key's
own requests. Sail reports money in fractional USD cents, which CodexBar converts to USD.

Spend uses the returned `effective_range`: Free organizations can receive seven days even when
30 days were requested. A failed balance lookup displays “Unavailable” while valid spend remains
visible. An organization without a billing account reports that state instead of showing a zero
balance. Negative balances remain visible. Billing data can lag recent activity.

This endpoint does not report a credit allowance or reset timestamp, so no percentage bars or
resets are inferred. Its rolling and billing windows describe the query interval; their end dates
are not credit resets. `days_remaining` is a spending projection, not a reset either.

Refreshes use only the declared HTTPS API origin and do not run inference, import cookies, discover
credentials in local files, or modify the account. Invalid billing values fail the refresh rather
than appearing as zero. No real-account verification was performed for this integration.

Public contract: [Usage API overview](https://docs.sailresearch.com/usage) and
[Usage API endpoints](https://docs.sailresearch.com/usage-endpoints), fetched October 8, 2026.
The icon and colors come from the [Sail Research website](https://www.sailresearch.com/).
Synthetic contract coverage: `swift test --filter SailResearchPluginTests` on both plugin engines.
