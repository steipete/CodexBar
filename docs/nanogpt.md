---
summary: "NanoGPT subscription token quotas, prepaid USD balance, and month-to-date spend from its account APIs."
provider_id: nanogpt
provider_name: NanoGPT
provider_source: NanoGPT inference API key for subscription input-token quotas, the prepaid USD balance, and month-to-date spend.
plugin_scope: Fixed-origin reads of subscription quotas, the prepaid balance, and usage totals on both engines; no login, cookie import, or inferred quotas.
read_when:
  - Configuring NanoGPT
  - Debugging NanoGPT quotas, balance, or monthly spend
---

# NanoGPT

NanoGPT is disabled by default. Paste a **NanoGPT API key** in Settings → Providers → NanoGPT, or set
`NANOGPT_API_KEY`. Keys are minted on the NanoGPT website. CodexBar only reads usage, so the key needs no
inference permission by itself; a read-only token is not required, but nothing is recorded as spent.

The bundled `nanogpt.ts` plugin makes at most three read-only requests against
`https://api.nano-gpt.com`:

```text
GET  /api/subscription/v1/usage   Authorization: Bearer <key>
POST /api/check-balance           x-api-key: <key>
GET  /api/v1/usage?from=…&to=…    Authorization: Bearer <key>
```

Offline and DNS failures on either GET keep the original URL error, so a launch can retry and the last usage
stays in place.

The subscription response drives the meters. Daily and weekly **input-token** lanes become the primary and
secondary windows, using the reported `resetAt` epoch-millisecond timestamps and the quota's own
`percentUsed`, which NanoGPT documents as a fraction that may exceed 1. A lane reported as `degraded`, or one with
`null` counters, stays visible but has no percentage. Image counts are a separate named extra window because they
are not tokens. Trial-token lanes from token-based trials show as detail rows only.

The balance response supplies the prepaid USD balance, shown as the cost snapshot's `balance`. Month-to-date spend
comes from the authenticated key's own `/api/v1/usage` totals: requests, total tokens, and `netCostUsd`, plus a
daily spend chart. That history is scoped by NanoGPT to the key, not the account, so two keys report separate
spend. The balance is account-wide. When both balance origins fail for any reason other than a rejected
key, the spend is still reported and `balance` is left unset.

Account plans and Design subscription columns on quota reports are separate from the balance; CodexBar never
converts one into the other. The API has no monthly reset for the balance, so none is invented.

The menu's Usage Dashboard opens [nano-gpt.com/usage](https://nano-gpt.com/usage). The pay-as-you-go
card always shows the prepaid balance and the month-to-date spend beside the subscription token meters.
Both amounts stay in USD, including when CodexBar's display currency is something else. Automatic menu
bar text uses that same balance; the daily and weekly token selections stay available.

NanoGPT recommends a billing mode per key in `routing.recommendedMode`. The Billing detail section shows that
recommendation and its `routing.reason`. Use it when choosing between included subscription usage and the paid
balance: a zero balance does not prove included tokens are exhausted, and `active: true` does not prove quota
remains.

```sh
codexbar usage --provider nanogpt --source api --json
```

Sources checked November 11, 2026:
- [Subscription Usage](https://docs.nano-gpt.com/api-reference/endpoint/subscription-usage), lanes, fraction `percentUsed`, millisecond `resetAt`, `degraded`, and routing advice.
- [Check Balance](https://docs.nano-gpt.com/api-reference/endpoint/check-balance), `usd_balance` and the `x-api-key` header.
- [Usage](https://docs.nano-gpt.com/api-reference/endpoint/usage), `/api/v1/usage` totals, UTC date bounds, and key scoping.

Check Balance is documented on both `https://api.nano-gpt.com/api/check-balance` and
`https://nano-gpt.com/api/check-balance`. The plugin uses the website host only when the API host does not serve
the route. Both origins are declared; the key is sent to no other host.
Tests use the documented response shapes with synthetic values on both JavaScript engines. No live account was used
to verify this integration.
