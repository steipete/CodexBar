---
summary: "Munito today and this month's spend against organization spend limits through the documented Admin API."
provider_id: munito
provider_name: Munito
provider_source: Admin API key with Read account data permission for today's and this month's spend against the organization's spend limits.
plugin_scope: Fixed-origin bearer GET for the spend limits and organization on both engines; no guessed reset time.
read_when:
  - Configuring Munito
  - Debugging Munito usage fetching
---

# Munito

Enable **Munito** in Settings → Providers and enter a Munito admin API key, or set `MUNITO_API_KEY` (or
`MUNITO_ADMIN_KEY`) for the CLI. The key is saved in CodexBar's local config file; a configured key takes precedence
over the environment. CodexBar sends the key only to `https://api.munito.ai` as `Authorization: Bearer …` and does not
import browser cookies or start a login flow.

Create the key in [console.munito.ai/keys](https://console.munito.ai/keys) with the **Read account data (Admin API)**
permission. Only owners and admins can create such a key. CodexBar makes read-only GET requests; an inference-only
key returns HTTP 403, which CodexBar reports as a permission problem rather than an expired key.

The bundled JavaScript plugin reads `GET /admin/v1/limits` and shows:

- **Today**: `spent_usd` against `limit_usd` as a daily window. Organization and account limits that differ from the
  applicable limit are listed as rows.
- **This month**: the month period's `spent_usd` against `limit_usd`, also shown as the cost meter with period
  "This month". When Munito reports only a day period, the meter keeps the day's spend as "Today".
- **Today stopped until / This month stopped until**: each period's full `stopped_until` timestamp when Munito has
  halted spending after a limit was hit. Both restrictions remain visible when their end times differ.
- **Usage tier**, plus the organization name, status, and data region from the best-effort `GET /admin/v1/organization`
  read. A slow or failing organization read never discards the spend limits.

Numeric-string amounts are accepted; missing or zero limits keep the spend rows without a percentage window, and an
empty `periods` array still shows the account card. Missing, negative, or nonfinite amounts fail parsing instead of
becoming zero. The API does not report a reset time, so CodexBar shows the daily window without a guessed countdown.

When the reported period has a positive limit, its budget is also available to menu bar **Spend** layout items and
conditions through the **Extra usage** metric.

```sh
codexbar usage --provider munito --source api --json
```

Sources checked October 14, 2026:
- [Administration](https://docs.munito.ai/administration)
- [Get spend limits](https://docs.munito.ai/api/getSpendLimits)
- [Get the organization](https://docs.munito.ai/api/getOrganization)

The monochrome icon reproduces the pixel-cube mark from [docs.munito.ai](https://docs.munito.ai/)'s favicon with
face-opacity shading; the website card uses the brand colors.
Tests use the documented Admin API schemas with synthetic values on QuickJS and JavaScriptCore.
No authenticated account was probed during implementation.
