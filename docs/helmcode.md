---
summary: "Helmcode provider notes: dashboard-session setup, monthly model quotas, and prepaid balance."
read_when:
  - Adding or modifying the Helmcode provider
  - Debugging Helmcode dashboard authentication or quota parsing
  - Updating Helmcode monthly quota or prepaid balance display
---

# Helmcode Provider

CodexBar reads the usage data shown by the Helmcode dashboards. Helmcode runs two tenants on the same platform:
the enterprise [Helmcode Cloud](https://cloud.helmcode.com) and the community [NaN Builders](https://nan.builders)
dashboard at [cloud.nan.builders](https://cloud.nan.builders) — NaN is Helmcode's community brand. Both tenants
expose identical dashboard APIs. Helmcode's public inference API is OpenAI-compatible, but its API keys do not
expose account quota or billing. The provider therefore authenticates with the user's Helmcode dashboard session
instead of an inference key.

## Deployment

Settings → Providers → Helmcode → **Deployment** selects the tenant. **Automatic** (default) detects the tenant
from the persisted session cache or the imported browser session; a cURL capture pasted in manual mode is also
host-detected, and a bare Cookie header falls back to Helmcode Cloud. Pin the tenant when you want to be explicit:

| Deployment | Dashboard | API host |
| --- | --- | --- |
| Automatic (default) | detected from the session | detected from the session |
| Helmcode Cloud | `cloud.helmcode.com` | `cloud-api.helmcode.com` |
| NaN Builders | `cloud.nan.builders` | `cloud-api.nan.builders` |

Cookie imports are scoped to the selected deployment's domains, so a session for one tenant is never sent to the
other. CLI users can select the tenant with `HELMCODE_DEPLOYMENT=nanbuilders` (accepts `nan`, `nan.builders`, or
`nanbuilders`), or `HELMCODE_DEPLOYMENT=auto` to force detection.

## Features

- Per-model monthly token allowances from the dashboard quota response.
- The capped model with the highest utilization as the primary usage window, with other capped models shown as named
  extra windows.
- Reset dates follow each model's `periodEnd`, falling back to the first day of the month after `periodStart`.
- Premium rolling-window tiers (GLM 5.3 premium) are hidden unless the subscription is premium.
- Prepaid credit balance displayed separately in the currency returned by Helmcode (EUR when omitted). NaN Builders
  membership has no prepaid balance.
- Provider identity remains Helmcode-only and does not borrow account or plan data from another provider.

## Setup

1. Sign in to your dashboard in Chrome using Helmcode's email-link login: [Helmcode Cloud](https://cloud.helmcode.com)
   or [NaN Builders](https://cloud.nan.builders).
2. Open **Settings → Providers** and enable **Helmcode**.
3. Leave **Deployment** on **Automatic** (it detects the tenant), or pin the tenant matching your subscription.
4. Leave **Cookie source** on **Automatic** and refresh Helmcode from the app.

Automatic cookie import is Chrome-only and runs on an explicit app refresh. After a validated refresh the dashboard
session is persisted in the cookie cache (scoped to the selected deployment) as cookie records with path and expiry
metadata, so later automatic refreshes — including background refreshes and the bundled CLI — reuse it without
rereading the browser. Cached sessions keep their per-cookie scope: a cookie limited to `/api/usage` is never sent
to billing, and an expired cookie is dropped by name. When every candidate is rejected, its cache scope is evicted
and nothing is committed until a quota request succeeds. A legacy flat-header cache entry is treated as a miss and
cleared. If automatic import cannot find the active session, switch to **Manual** and paste either the browser's
`Cookie:` request header or a cURL capture from the Helmcode dashboard; a cURL capture also decides the tenant
(host detection), so the paste is only ever sent to the dashboard it came from.

For CLI use, set the same value in `HELMCODE_COOKIE` (plus the deployment when using NaN Builders):

```bash
HELMCODE_COOKIE='session=...' codexbar usage --provider helmcode --source web
HELMCODE_COOKIE='session=...' HELMCODE_DEPLOYMENT=nanbuilders codexbar usage --provider helmcode --source web
```

CLI users can also persist the deployment in `config.json` instead of the environment variable
(`region` carries the deployment selection: `auto` | `helmcode` | `nanBuilders`):

```json
{
  "version": 1,
  "providers": [
    {
      "id": "helmcode",
      "enabled": true,
      "region": "nanBuilders"
    }
  ]
}
```

## Data source

- Required: `GET https://<api-host>/api/usage/quota`
- Best-effort: `GET https://<api-host>/api/billing` (subscription plan flags)
- Optional: `GET https://<api-host>/api/billing/credits` (Helmcode Cloud prepaid balance; NaN Builders has no
  prepaid balance — the membership subscription has none, so the endpoint answers 404 there)
- Request context: the dashboard Cookie header plus the selected deployment's `Origin` and `Referer` headers.
- Tenant selection is validated: in Automatic mode cached sessions (newest first) and imported sessions
  (Helmcode Cloud first) are candidates; a rejected candidate's cache scope is evicted and the next candidate
  is tried, and nothing is committed until a quota request answers 200. With `--verbose` the CLI prints the
  boundary per request (host, path, cookie names, and excluded expired/path-mismatched cookies — never values).

The quota response provides `periodStart` and a `models` array. CodexBar maps each positive `cap` against
`tokensUsed`; `creditTokens` is included in the usage detail when present. Each model entry's own `periodEnd`
drives its reset date, falling back to the first day of the month after `periodStart`. Entries carrying a
`windowHours` rolling window belong to the premium tier ("GLM 5.3 premium"); when the billing response reports
`premium == false` those entries are hidden, and a rolling window renders with its window length
(`windowHours * 60` minutes). The billing response is otherwise unused for display in this round. The credits
endpoint reports `balanceMicros`, converted at one million micros per currency unit.

These are endpoints used by the current Helmcode dashboard rather than a versioned public billing API. Quota parsing
therefore fails visibly if its required response changes. Billing and credit lookups and parsing are best-effort so a
billing surface change cannot hide otherwise valid model quota.

## Troubleshooting

- **No dashboard session found:** sign in to the dashboard for your selected deployment in Chrome, then trigger a
  manual refresh in CodexBar.
- **Session expired:** sign in again, or replace the manually configured Cookie header.
- **Automatic picked the wrong tenant:** pin the tenant under **Settings → Providers → Helmcode → Deployment**;
  the cookie import and
  endpoints follow the selected deployment.
- **Quota works but balance is absent:** the credits request is deliberately optional; refresh later or inspect the
  Helmcode dashboard to confirm the billing surface is available for the account.
- **Using Helmcode through OpenCode:** OpenCode usage can still be tracked by its own CodexBar integration, but that
  does not expose Helmcode account quota or prepaid balance. Enable this provider to see the Helmcode-side allowance.
