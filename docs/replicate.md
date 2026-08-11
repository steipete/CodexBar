---
summary: "Replicate provider: browser cookie setup, monthly spend from billing invoices, and prepaid credit balance."
read_when:
  - Configuring Replicate usage
  - Debugging Replicate billing cookie or invoice requests
  - Adjusting Replicate spend or credit display
---

# Replicate Provider

CodexBar reads Replicate billing data with the Replicate web session from `replicate.com`. It shows **current calendar-month spend**
from the draft `monthly-usage` invoice and, when available, prepaid **unused credit** balance.

Replicate public API tokens cannot supply spend or credit data — CodexBar requires a signed-in billing dashboard session.

## Setup

1. Open **Settings → Providers**.
2. Enable **Replicate**.
3. Sign in to [Replicate Billing](https://replicate.com/account/billing) in Chrome (Automatic), or any browser if you
   will paste a Manual Cookie header.
4. Leave Cookie source on **Automatic**, or switch to **Manual** and paste a `Cookie:` header from a request to
   `replicate.com`.

Manual cookies must include a Django-style `sessionid` cookie. A `csrftoken` cookie is imported when present but is not
required for the read-only billing GET requests CodexBar makes.

Automatic import is Chrome-only by default (to avoid extra Keychain / Full Disk Access prompts). Use Manual mode for
Firefox, Safari, or other Chromium browsers. Automatic import reads only unexpired cookies from `replicate.com`.

## Data Sources

CodexBar bootstraps the signed-in account by fetching the billing dashboard HTML and parsing embedded React page props
for `account: { kind, username }`. It then requests user- or organization-scoped billing JSON depending on `kind`:

- `GET https://replicate.com/api/users/{username}/invoices` (personal accounts)
- `GET https://replicate.com/api/organizations/{organization_name}/invoices` (organization accounts)

From the invoices response, CodexBar filters `invoices[]` where `type == "monthly-usage"`, selects the current draft
invoice (the row with a null or future `ended_before`), and reads **Usage this month** from
`total_cost_before_adjustments` (string decimal, USD implied when absent).

Best-effort prepaid credit:

- `GET https://replicate.com/api/users/{username}/unused-credit`
- `GET https://replicate.com/api/organizations/{organization_name}/unused-credit`

Credit balance comes from `unused_credit` (string number). Credit fetch failures do not fail the primary spend result.

## Display

- The menu bar shows current calendar-month spend in dollars (e.g. `$12.34`).
- The provider card shows prepaid credit balance when the unused-credit endpoint returns it.
- Spend limit is omitted in v1 — Replicate exposes set-spend-limit POST routes but no confirmed JSON read API.
- Resets at end of calendar month (aligned with the monthly-usage invoice period).

## CLI Usage

```bash
codexbar usage --provider replicate --verbose
```

## Troubleshooting

### "No Replicate session cookies found"

Sign in to [Replicate Billing](https://replicate.com/account/billing) in Chrome (Automatic) or paste a Manual Cookie
header, then refresh.

### "Replicate cookie header is invalid"

In manual mode, paste a full `Cookie:` header from a `replicate.com` request. The header must include a `sessionid`
cookie. Manual mode also works on Linux CLI without browser import.

### HTTP 401/403 or "Replicate session rejected"

The billing session expired or the cookie header is stale. Sign in again, copy a fresh `Cookie:` header, or let
Automatic mode re-import from Chrome (stale cached headers are cleared when the billing page returns a sign-in
session).

### Credit balance is missing

Monthly spend is required. Unused credit is best-effort; if the endpoint fails or the account has no prepaid balance,
CodexBar keeps the main spend result.

## Related Files

- `Sources/CodexBarCore/Providers/Replicate/ReplicateProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Replicate/ReplicateBillingEndpoints.swift`
- `Sources/CodexBarCore/Providers/Replicate/ReplicateUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/Replicate/ReplicateCookieImporter.swift`
- `Sources/CodexBarCore/Providers/Replicate/ReplicateModels.swift`
- `Sources/CodexBar/Providers/Replicate/ReplicateProviderImplementation.swift`
