---
summary: "Parallel prepaid credit balance through the signed-in platform.parallel.ai browser session."
provider_id: parallel
provider_name: Parallel
provider_source: Browser session on platform.parallel.ai for the prepaid credit balance and pending debit.
plugin_scope: Fixed-origin session-cookie POST to the platform dashboard's internal balance endpoint on both engines; no API key, allowance, usage history, or reset.
read_when:
  - Configuring Parallel
  - Debugging Parallel balance fetching
---

# Parallel

Enable **Parallel** in Settings → Providers and sign in to
[platform.parallel.ai](https://platform.parallel.ai/login) in any supported browser. Automatic imports the
`platform.parallel.ai` session in the shared browser order. To skip the import, switch the
cookie source to **Manual** and paste the `Cookie` header from a signed-in `platform.parallel.ai` request.
**Off** disables the provider's cookie access.

## What it reads

The bundled JavaScript plugin sends the same request the platform dashboard makes when it refreshes the billing page:

```
POST https://platform.parallel.ai/api/rpc/billing/payments/refresh-balance
Content-Type: application/json
Origin: https://platform.parallel.ai

{}
```

A successful response looks like
`{"kind":"ok","data":{"balance":1234,"pendingDebitBalanceCents":0}}`, with both amounts in US cents.
CodexBar shows:

- **Balance**: `data.balance` as dollars. It is also the value shown in the menu bar's balance layouts.
- **Pending debit**: `data.pendingDebitBalanceCents` as dollars, only when it is present and not zero.

The endpoint reports no allowance, usage history, or reset date, so CodexBar shows the amount without a percentage.

## This endpoint is not a public API

The balance comes from an internal, undocumented dashboard endpoint. Parallel can change or remove it at any time,
and CodexBar would then stop showing a balance until the plugin is updated. Parallel's official balance route is
part of its Account API, which needs an OAuth sign-in that CodexBar's plugin host does not support yet
([#4345](https://github.com/steipete/CodexBar/issues/4345)). Parallel API keys cannot read the balance, so this
provider has no API-key source.

Because the format can drift, the plugin checks the response shape and fails loudly instead of guessing:

| Response | Result |
| --- | --- |
| HTTP 200 with `kind: "ok"` and a numeric `data.balance` | Balance shown |
| HTTP 200 with any other shape, including `kind: "error"` or a missing or non-numeric balance | Parse error: "Parallel billing response format changed" |
| HTTP 401, 403, 3xx, or an HTML login page | Session expired: sign in again or paste a fresh Cookie header |
| HTTP 429 | Rate limited, honoring `Retry-After` up to 10 seconds |
| HTTP 408 or 5xx | Parallel unavailable |

A format change surfaces as a parse error, never as a zero balance.

```sh
codexbar usage --provider parallel --source web --json
```

The monochrome icon is Parallel's mark from `https://parallel.ai/views/icons/logo-parallel.svg` on the
company's own site. Tests use synthetic responses on QuickJS and JavaScriptCore; no account was probed by the tests.
