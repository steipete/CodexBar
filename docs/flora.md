---
summary: "FLORA workspace balance and month-to-date spend through the documented workspace usage API."
provider_id: flora
provider_name: FLORA
provider_source: API key with billing permission plus a workspace ID for the available USD balance and month-to-date spend.
plugin_scope: Fixed-origin bearer GET for one configured workspace's balance, member limit, and UTC month-to-date spend on both engines; no inferred allowance or reset.
read_when:
  - Configuring FLORA
  - Debugging FLORA balance fetching
---

# FLORA

Enable **FLORA** in Settings → Providers, enter a FLORA API key (`ak_…`) and the workspace ID (`ws_…`), or set
`FLORA_API_KEY` and `FLORA_WORKSPACE_ID` for the CLI. Both are saved in CodexBar's local config file; configured values
take precedence over the environment. CodexBar sends the key only to `https://app.flora.ai` as
`Authorization: Bearer …` and does not import browser cookies or start a login flow.

Create the key in FLORA under Settings → API Keys and grant it **billing** on the workspace. The workspace ID is
required: FLORA's `GET /api/v1/workspaces` lists only workspaces where the key has read access, and in practice an
API key received an empty list, so CodexBar does not try to discover it. Copy the `ws_…` ID from the workspace URL.

The bundled JavaScript plugin reads
`GET /api/v1/workspaces/{workspace_id}/usage?start_date=<first of month>&end_date=<today>` in UTC and shows:

- **Available**: `available_cost`, which is current and not limited to the period. `balance_scope` labels it as the
  workspace pool (billing users on plans with usage reporting) or your own allowance (everyone else).
- **Member limit**: present only for `caller` scope when FLORA reports a monthly or all-time limit on the member.
- **Spent this month** and **Runs this month**: `spend.total_cost` and `spend.classified_runs` when spend is available.
  When FLORA reports spend as unavailable, the row says so with the documented reason (plan without usage reporting,
  missing billing permission, or totals not computed) instead of showing zero.

A missing or nonfinite `available_cost`, or an available spend block without a finite total, fails parsing.
HTTP 403 means the key lacks billing permission on that workspace; 404 means the workspace ID was not found.
The endpoint reports no allowance or reset date, so CodexBar shows amounts without a percentage or guessed reset.

```sh
codexbar usage --provider flora --source api --json
```

Sources checked October 11, 2026:
- [Get workspace balance and usage](https://developer.flora.ai/reference/operations/getworkspaceusage/)
- [Workspaces](https://developer.flora.ai/guides/workspaces/)
- [Authentication and key permissions](https://developer.flora.ai/platform/authentication/)
- [Errors](https://developer.flora.ai/platform/errors/)

The monochrome icon uses FLORA's standalone Flower mark from the [brand page](https://www.flora.ai/brand).
Tests use the documented usage schema with synthetic values on QuickJS and JavaScriptCore.
No authenticated account was probed during implementation.
