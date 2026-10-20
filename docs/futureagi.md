---
summary: "Future AGI usage and free allowances through its authenticated billing API."
provider_id: futureagi
provider_name: Future AGI
provider_source: API key and secret key (billing-period usage, allowances, and estimated cost).
plugin_scope: Required usage-overview GET; API-key pair; no cookies or inference calls.
read_when:
  - Configuring Future AGI usage
---

# Future AGI

Enable Future AGI in Settings → Providers and enter both the **API key** and **Secret key** from your
Future AGI account, or set `FI_API_KEY` and `FI_SECRET_KEY`. Both fields are masked and saved in
CodexBar's local config file. Configured values override their environment equivalents.
For CLI-only configuration, use the two environment variables; the usual `set-api-key` command
sets only the API key, not the required companion secret.

Auto and API use the bundled plugin on both engines. It reads
`GET https://api.futureagi.com/usage/v2/usage-overview/` with `X-Api-Key` and `X-Secret-Key`.
The account and workspace access follow the supplied key pair. No cookies, browser storage,
login flow, or inference request is involved.

The main windows show AI credits and gateway requests against the free allowances returned by
the API. Other returned meters appear in the details, along with estimated usage cost. Allowances
are not hard spending limits: paid usage may continue after they are exhausted. Percentage bars
clamp at 100%, while the original usage amounts remain visible. A zero allowance does not produce
a percentage bar. Billing-period dates come from the response; no monthly dates or plan amounts
are hardcoded. Platform subscription fees are not included in the estimated usage cost.

Missing credentials, rejected keys, rate limits, service failures, and malformed responses report
errors rather than invented usage. No real-account verification was performed.

Public contracts: [production OpenAPI](https://api.futureagi.com/docs/?format=openapi),
[usage and billing](https://docs.futureagi.com/docs/billing/guides/control-spend), and
[API-key authentication](https://github.com/future-agi/future-agi/blob/3257f9614f7837bf6787bc5cccdb52d371142150/futureagi/accounts/authentication.py#L193).
