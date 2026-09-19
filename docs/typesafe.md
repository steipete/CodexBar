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

Automatic mode imports Chrome cookies from `typesafe.ai`, covering both host-only `console.typesafe.ai` cookies and
cookies scoped to `.typesafe.ai`. The session cookie name is intentionally not assumed. Manual mode accepts the full
`Cookie:` header captured from `https://console.typesafe.ai/settings/billing`, which also supports sessions held in
other browsers and Linux.

## Implementation

The bundled `typesafe.ts` plugin owns the billing requests and parsing. It discovers the current Next.js server-action
ID from the billing page's static chunks, caches it for 12 hours, and rediscovers it once when the server reports a
stale action ID. The read-only action sends `Origin`, `Next-Action`, `Cookie`, and a JSON `[]` body, then parses the
`text/x-component` result.

Like other balance-only providers, the header shows `Balance $x`; the Billing rows show cycle spend, the plan label,
and non-zero credits with their expiration month/day. With the inline cost summary enabled, spend and balance move into
the pay-as-you-go card. Credit expiration and the API's `resetsInDays` are not quota resets. Malformed required billing
numbers are parsing failures, while 401/403, redirects/login landings, rate limits, and transient server errors keep
their distinct authentication or availability classifications.
