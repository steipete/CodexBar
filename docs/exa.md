---
summary: "Exa selected-key monthly spend through the Team Management API."
provider_id: exa
provider_name: Exa
provider_source: Team Management service key plus an explicit API key ID for month-to-date USD spend.
plugin_scope: Selected-key billing on both engines; no inferred team balance, allowance, or reset.
read_when:
  - Configuring Exa
  - Debugging Exa usage fetching
---

# Exa

Exa creates a **Personal Team** for each individual account. Its Team Management API must be enabled for that
team by Exa support before usage can be read. Request access from `support@exa.ai`, then create a service account
API key under **Service keys** on the [API keys page](https://dashboard.exa.ai/api-keys).
This service key can manage API keys for its team; CodexBar uses it only for the read-only usage endpoint.
Ordinary search API keys cannot authenticate this endpoint.

Enable **Exa** in Settings → Providers. Enter the service key in **API key** and the identifier of the API key
whose spend you want to monitor in **Scope**. The identifier is not the secret value of either key.
Both keys must belong to the same team. The CLI accepts `EXA_SERVICE_KEY` and `EXA_API_KEY_ID`.
Settings are saved in CodexBar's local config file; the selected key ID uses its `workspaceID` field.

The bundled JavaScript plugin sends the service key only to `https://admin-api.exa.ai` in the `x-api-key` header.
It reads `GET /team-management/api-keys/{id}/usage` with `start_date` at the start of the current UTC calendar
month and `end_date` at refresh time, rounded down to whole seconds. CodexBar shows the reported `total_cost_usd`
for that selected API key.
Zero spend stays visible. Malformed, nonfinite, negative, or mismatched-period responses fail parsing.

This is selected-key spend, not the team's total spend or prepaid credit balance. CodexBar does not infer quota,
remaining credits, request-rate headroom, a billing reset, or a next top-up date. Account history and burn-down
widgets are unavailable because the plugin does not expose a stable account identity. No browser cookies are imported.

```sh
codexbar usage --provider exa --source api --json
```

Sources checked October 8, 2026:
- [Personal Teams and Team Management access](https://exa.ai/docs/admin/team-management)
- [Get API key usage](https://exa.ai/docs/reference/team-management/get-api-key-usage)
- [Team Management OpenAPI schema](https://exa.ai/docs/team-management-spec.yaml)
- [Official Exa logo](https://exa.ai/images/logo/exa-logo-blue.svg), using its standalone symbol.

Tests use synthetic usage responses on QuickJS and JavaScriptCore. No authenticated account was probed.
