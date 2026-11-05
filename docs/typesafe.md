---
summary: "TypeSafe billing spend and credit balance through the console session."
read_when:
  - Configuring TypeSafe in CodexBar
  - Debugging TypeSafe billing or session parsing
  - Adding or tweaking TypeSafe usage parsing
---

# TypeSafe

TypeSafe shows the billing-page spend and current credit balance without inventing a usage percentage, quota, or
reset date. It is disabled by default.

## Authentication

Automatic mode imports `typesafe.ai` cookies from every supported browser in the shared catalog order, covering both
host-only `console.typesafe.ai` cookies and cookies scoped to `.typesafe.ai`. The session cookie name is intentionally
not assumed. Manual mode accepts the full `Cookie:` header captured from
`https://console.typesafe.ai/billing`, which also covers Linux.
Imported cookies must match the console host and `/api/billing/overview` path; longer matching paths take precedence.
Cached cookie headers from older billing routes are never reused. Requests use an isolated session without ambient
cookies and do not follow redirects: a redirect to a login/SSO route is treated as an expired session, while any other
redirect is reported as an API failure with a next-action hint. An inference API key does not replace a console
session.

## Implementation

The bundled `typesafe.ts` plugin owns the billing request and parsing. It sends one read-only `GET` to
`https://console.typesafe.ai/api/billing/overview` with the selected `Cookie:` header and reads `json.billing`.
The request sends a browser-style User-Agent and `Accept: application/json` so Cloudflare does not reject Linux
URLSession requests that otherwise identify as curl. A 200 HTML login page is treated as an expired session; JSON parse
failures and a missing `billing` object are parsing failures.
Large credit lists show a bounded set of rows plus an additional-credit count; the reported balance and spending totals
stay unchanged.

Like other balance-only providers, the header and menu bar show the balance (`Balance $x` and `$x`). The menu bar's
automatic percentage and explicit Balance tokens use the same balance, including in the layout preview.
The Billing rows show cycle spend, the plan label, and non-zero credits with their expiration month/day.
With the inline cost summary enabled, spend and balance move into
the pay-as-you-go card. Credit expiration and the API's `resetsInDays` are not quota resets. Malformed required billing
numbers, invalid JSON, or a missing `billing` object are parsing failures, while 401/403, login redirects or login
landing pages, rate limits, and transient server errors keep their distinct authentication or availability
classifications.
