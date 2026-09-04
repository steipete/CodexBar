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

Settings → Providers → Helmcode → **Deployment** selects the tenant:

| Deployment | Dashboard | API host |
| --- | --- | --- |
| Helmcode (default) | `cloud.helmcode.com` | `cloud-api.helmcode.com` |
| NaN Builders | `cloud.nan.builders` | `cloud-api.nan.builders` |

Cookie imports are scoped to the selected deployment's domains, so a session for one tenant is never sent to the
other. CLI users can select the tenant with `HELMCODE_DEPLOYMENT=nanbuilders` (accepts `nan`, `nan.builders`, or
`nanbuilders`).

## Features

- Per-model monthly token allowances from the dashboard quota response.
- The capped model with the highest utilization as the primary usage window, with other capped models shown as named
  extra windows.
- Monthly reset derived from `periodStart`: the first day of the following UTC month.
- Prepaid credit balance displayed separately in the currency returned by Helmcode (EUR when omitted).
- Provider identity remains Helmcode-only and does not borrow account or plan data from another provider.

## Setup

1. Sign in to your dashboard in Chrome using Helmcode's email-link login: [Helmcode Cloud](https://cloud.helmcode.com)
   or [NaN Builders](https://cloud.nan.builders).
2. Open **Settings → Providers** and enable **Helmcode**.
3. Select the **Deployment** matching your subscription (Helmcode or NaN Builders).
4. Leave **Cookie source** on **Automatic** and refresh Helmcode from the app.

Automatic cookie import is Chrome-only and runs on an explicit app refresh. It does not run during ordinary CLI or
test execution. If automatic import cannot find the active session, switch to **Manual** and paste either the browser's
`Cookie:` request header or a cURL capture from the Helmcode dashboard.

For CLI use, set the same value in `HELMCODE_COOKIE` (plus the deployment when using NaN Builders):

```bash
HELMCODE_COOKIE='session=...' codexbar usage --provider helmcode --source web
HELMCODE_COOKIE='session=...' HELMCODE_DEPLOYMENT=nanbuilders codexbar usage --provider helmcode --source web
```

## Data source

- Required: `GET https://<api-host>/api/usage/quota`
- Optional: `GET https://<api-host>/api/billing/credits`
- Request context: the dashboard Cookie header plus the selected deployment's `Origin` and `Referer` headers.

The quota response provides `periodStart` and a `models` array. CodexBar maps each positive `cap` against
`tokensUsed`; `creditTokens` is included in the usage detail when present. The credits endpoint reports
`balanceMicros`, converted at one million micros per currency unit.

These are endpoints used by the current Helmcode dashboard rather than a versioned public billing API. Quota parsing
therefore fails visibly if its required response changes. Credit lookup and credit parsing are best-effort so a billing
surface change cannot hide otherwise valid model quota.

## Troubleshooting

- **No dashboard session found:** sign in to the dashboard for your selected deployment in Chrome, then trigger a
  manual refresh in CodexBar.
- **Session expired:** sign in again, or replace the manually configured Cookie header.
- **Data shows the wrong tenant:** check **Settings → Providers → Helmcode → Deployment**; the cookie import and
  endpoints follow the selected deployment.
- **Quota works but balance is absent:** the credits request is deliberately optional; refresh later or inspect the
  Helmcode dashboard to confirm the billing surface is available for the account.
- **Using Helmcode through OpenCode:** OpenCode usage can still be tracked by its own CodexBar integration, but that
  does not expose Helmcode account quota or prepaid balance. Enable this provider to see the Helmcode-side allowance.
