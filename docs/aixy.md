---
summary: "Aixy API-key setup, key-scoped usage, and applicable budget balances."
read_when:
  - Configuring Aixy usage tracking
  - Troubleshooting Aixy budgets or reporting access
---

# Aixy

[Aixy](https://aixy-gateway.com) is an AI gateway using customer-configured provider credentials.
CodexBar reads the Aixy key's own usage and applicable budget aggregates. It does not call model
providers, make inference requests, or use an Aixy administrator credential or browser session.

## Setup

Create or select the project-scoped Aixy API key used by the workload you want to track. Configure
it in Settings → Providers → Aixy. Leave Base URL empty for `https://api.aixy-gateway.com`; set it
for a self-hosted or dedicated gateway. Each key reports its own traffic, including activity from
other machines using that key. The key is still capable of inference; it is not a read-only token.

Equivalent provider configuration:

```json
{
  "id": "aixy",
  "enabled": true,
  "apiKey": "<AIXY_API_KEY>",
  "enterpriseHost": "https://api.aixy-gateway.com"
}
```

`enterpriseHost` is optional. Environment variables are `AIXY_API_KEY` and `AIXY_BASE_URL`.
The CLI uses `codexbar usage --provider aixy --source api`.

The base URL may include a path prefix and a trailing `/v1`. HTTPS is required for public hosts;
loopback, private-network, and `.local` HTTP are supported for self-hosted installations. URLs with
embedded credentials, query strings, or fragments are rejected. Keys are sent only to the selected
gateway origin and are stored using CodexBar's normal provider-config/token-account storage.

Only the Automatic menu bar metric is offered because the selected budget depends on the current applicable limits.

## Data source and display

The bundled TypeScript provider calls `GET {baseURL}/v1/usage` with
`Authorization: Bearer <AIXY_API_KEY>`. See Aixy's generated
[API documentation](https://docs.aixy-gateway.com) and
[usage guidance](https://docs.aixy-gateway.com/observe/usage).

- **Budgets:** key, user, team, project, and organization limits that affect this key. Hard limits
  come first; within that group the highest utilized known balance is primary, followed by the
  next known budget. Other budgets remain visible as named windows. Scope, period, shared/personal
  allocation, and hard/monitor enforcement are labeled. Overlapping limits are never summed.
- **Hard availability:** the bar includes settled ledger spend and outstanding reservations;
  details separate these amounts. A reservation is not a confirmed provider charge. Monitor budgets
  use recorded spend. Unknown balances remain **Unavailable**, with reset metadata when supplied.
- **Reset dates:** read from Aixy, including actual monthly calendar boundaries. Lifetime budgets
  have no invented reset. Reporting remains available when a hard budget is exhausted.
- **This key's usage:** requests, tokens, attributed USD spend, and attribution coverage over the
  retained last seven days. These totals are independent of budget cycles and may lag enforcement.
  Spend can be estimated or partial and is not a provider invoice. Missing analytics are not zero; an idle key with explicit zero spend keeps its budgets and shows $0.00.
- **No budgets:** usage remains visible without inventing a quota or credit balance. The response's
  key and project labels identify the reporting scope; no email or organization identity is guessed.

Disabled, revoked, expired, or otherwise inactive keys return an authentication error. A 404 means
the selected Aixy gateway needs the usage endpoint or its base URL is incorrect. There is no
browser-cookie or inference fallback. Prefer a refresh interval of at least one minute.

## Operator and access model

The hosted service's operator and jurisdiction are identified in Aixy's
[legal notice](https://aixy-gateway.com/legal-notice/). Upstream access uses the customer's configured
provider credentials; this integration reports Aixy usage and does not provide or resell model access.
Self-hosted gateways use the same reporting contract and configurable base URL.
