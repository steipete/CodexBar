---
summary: "Soniox organization API key setup, prepaid balance, and monthly budget usage."
provider_id: soniox
provider_name: Soniox
provider_source: Organization API key for prepaid USD balance and monthly spend against the organization budget.
plugin_scope: Read-only organization balance and monthly usage through the official API on both engines.
read_when:
  - Configuring Soniox
  - Debugging Soniox authentication or monthly usage
---

# Soniox

Enable Soniox in **Settings → Providers** and enter an **Organization API key**. An organization admin can create
one in [Soniox Console](https://console.soniox.com) under **Settings → Organization API keys**. Enable only
**Balance and spend** and **Usage and limits** access. Project API keys cannot read organization billing.

The key is stored in the CodexBar config file. The CLI also accepts `SONIOX_ORG_API_KEY`, or a stored key:

```sh
printf '%s' "$SONIOX_ORG_API_KEY" | codexbar config set-api-key --provider soniox --stdin
codexbar usage --provider soniox --source api
```

Refresh never submits transcription or synthesis work. The provider uses bearer authentication for two read-only requests to `https://api.soniox.com`:

- `GET /v1/organization/balance`: remaining prepaid USD balance and invoice billing state.
- `GET /v1/organization/usage/monthly`: current calendar month's total USD usage and organization budget.

The menu shows prepaid balance and monthly spend by default. Under **Settings → Providers → Soniox → Visible
usage items**, enable **Monthly budget** to show the budget meter and reset. The **Billing** checkbox controls the
billing-method details. Restore Defaults hides the budget meter again. These display choices do not change the API
data or CLI output.

Monthly usage includes API and Console playground requests across all projects. The budget meter resets at the
start of the next UTC calendar month. The budget is a spending cap, separate from the prepaid balance. Invoice
billing accounts show monthly spend without presenting a zero prepaid balance as exhausted credits.
A zero budget is shown as a dollar amount without inventing a usage percentage. Project breakdowns and daily
cost history are not collected.

HTTP 401 means the key is invalid or revoked. HTTP 403 means a project key was supplied or an organization key
lacks the required permissions. Update the key's permissions in Soniox Console; changes can take a few minutes
to apply. HTTP 429 means the organization's shared API rate limit was reached.

References: [Organization API](https://soniox.com/docs/guides/organization-api),
[balance](https://soniox.com/docs/api-reference/organization/get_organization_balance),
[monthly usage](https://soniox.com/docs/api-reference/organization/get_organization_monthly_usage).
