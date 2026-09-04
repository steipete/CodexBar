---
summary: "Helmcode provider notes: dashboard-session setup, monthly model quotas, and prepaid balance."
read_when:
  - Adding or modifying the Helmcode provider
  - Debugging Helmcode dashboard authentication or quota parsing
  - Updating Helmcode monthly quota or prepaid balance display
---

# Helmcode Provider

CodexBar reads the usage data shown by [Helmcode Cloud](https://cloud.helmcode.com). Helmcode's public inference API is
OpenAI-compatible, but its API keys do not expose account quota or billing. The provider therefore authenticates with
the user's Helmcode dashboard session instead of an inference key.

## Features

- Per-model monthly token allowances from the dashboard quota response.
- The capped model with the highest utilization as the primary usage window, with other capped models shown as named
  extra windows.
- Monthly reset derived from `periodStart`: the first day of the following UTC month.
- Prepaid credit balance displayed separately in the currency returned by Helmcode (EUR when omitted).
- Provider identity remains Helmcode-only and does not borrow account or plan data from another provider.

## Setup

1. Sign in to [Helmcode Cloud](https://cloud.helmcode.com) in Chrome using Helmcode's email-link login.
2. Open **Settings → Providers** and enable **Helmcode**.
3. Leave **Cookie source** on **Automatic** and refresh Helmcode from the app.

Automatic cookie import is Chrome-only and runs on an explicit app refresh. It does not run during ordinary CLI or
test execution. If automatic import cannot find the active session, switch to **Manual** and paste either the browser's
`Cookie:` request header or a cURL capture from the Helmcode dashboard.

For CLI use, set the same value in `HELMCODE_COOKIE`:

```bash
HELMCODE_COOKIE='session=...' codexbar usage --provider helmcode --source web
```

## Data source

- Required: `GET https://cloud-api.helmcode.com/api/usage/quota`
- Optional: `GET https://cloud-api.helmcode.com/api/billing/credits`
- Request context: the dashboard Cookie header plus Helmcode Cloud `Origin` and `Referer` headers.

The quota response provides `periodStart` and a `models` array. CodexBar maps each positive `cap` against
`tokensUsed`; `creditTokens` is included in the usage detail when present. The credits endpoint reports
`balanceMicros`, converted at one million micros per currency unit.

These are endpoints used by the current Helmcode dashboard rather than a versioned public billing API. Quota parsing
therefore fails visibly if its required response changes. Credit lookup and credit parsing are best-effort so a billing
surface change cannot hide otherwise valid model quota.

## Troubleshooting

- **No dashboard session found:** sign in to Helmcode Cloud in Chrome, then trigger a manual refresh in CodexBar.
- **Session expired:** sign in again, or replace the manually configured Cookie header.
- **Quota works but balance is absent:** the credits request is deliberately optional; refresh later or inspect the
  Helmcode dashboard to confirm the billing surface is available for the account.
- **Using Helmcode through OpenCode:** OpenCode usage can still be tracked by its own CodexBar integration, but that
  does not expose Helmcode account quota or prepaid balance. Enable this provider to see the Helmcode-side allowance.
