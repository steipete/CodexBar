---
summary: "Replicate billing through a bundled JavaScript provider with native session selection."
read_when:
  - Adding or debugging Replicate usage
---

# Replicate

Replicate shows **spend this month** and, when available, **prepaid credit balance**. It does not infer a usage percentage or spending limit. Enable the provider in Settings; it is off by default.

## Authentication

Automatic mode imports existing Chrome cookies for exactly `replicate.com`. It first tries the cached session, then imports candidates once if that session expires. Only authentication failures advance to another candidate; pinned cached accounts prohibit fallback. A temporarily unreadable Keychain cache stops automatic recovery until it can be read. Unrecognized HTML or changed JSON props are parsing failures and retain the selected credential. The successful candidate is cached conditionally so a late refresh cannot overwrite newer credentials. The read-only billing endpoints need a nonempty `sessionid`; a CSRF cookie is optional.

Manual mode accepts a Cookie header captured from a request to `https://replicate.com/account/billing`. It bypasses browser import and the automatic cookie cache, works on Linux, and supports named token accounts. The separate Replicate API token is not a website session credential.

## Implementation

Native code owns local credential selection, browser import and cache recovery. The bundled `replicate.ts` plugin owns all network requests and parsing:

1. GET the billing page with `Accept: text/html` and resolve the selected user or organization from its JSON React props.
2. GET that account's invoices and use the current `monthly-usage` invoice's `total_cost_before_adjustments` as required spend.
3. Best-effort GET the same account's `unused-credit`; omit balance if unavailable.

Missing or malformed required spend is an error, never a fabricated zero. Optional credit failure preserves valid spend. No local history scan or account mutation is performed. Both plugin engines have synthetic transport coverage; current-account compatibility needs real session verification.
