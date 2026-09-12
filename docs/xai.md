---
summary: "xAI provider: Management API key + team ID setup, prepaid balance, and daily platform spend."
read_when:
  - Configuring xAI platform usage
  - Debugging xAI Management API requests
---

# xAI Provider

CodexBar reads the prepaid credit balance and daily USD spend of an xAI developer-platform team from xAI's documented
Management API.

This provider is intentionally separate from the [Grok provider](grok.md): Grok tracks consumer Grok/SuperGrok
subscription quota through the Grok CLI or a grok.com session, while xAI tracks the developer-platform prepaid billing
surface. Credentials, balances, and identity are never shared between the two.

## Authentication

Create a **Management API key** in the [xAI Console](https://console.x.ai) under Settings > Management Keys, then add
it together with your **team ID** in CodexBar Settings → Providers → xAI. Inference API keys are not accepted by the
Management API. The team ID is shown in the xAI Console URL and team settings.

You can also use environment variables:

```bash
export XAI_MANAGEMENT_API_KEY="..."
export XAI_TEAM_ID="..."
```

Or configure the key through the CLI and the team ID in the config file:

```bash
printf '%s' "$XAI_MANAGEMENT_API_KEY" | codexbar config set-api-key --provider xai --stdin
```

```json
{
  "id": "xai",
  "enabled": true,
  "apiKey": "<XAI_MANAGEMENT_API_KEY>",
  "workspaceID": "<XAI_TEAM_ID>"
}
```

## Data Source

CodexBar requests:

- `GET https://management-api.x.ai/v1/billing/teams/{team_id}/prepaid/balance`
- `POST https://management-api.x.ai/v1/billing/teams/{team_id}/usage` with a daily, USD-summed analytics query for the
  last 30 days (UTC), as best-effort history enrichment.

Both requests use `Authorization: Bearer <management key>`. CodexBar does not read browser cookies, console sessions,
or inference traffic for this provider.

The balance endpoint reports an inverted ledger in string USD cents — a $10 top-up appears as `"-1000"` — so the
remaining balance is the negated cent value. A response without a parseable total is treated as an error, never as a
$0.00 balance.

The displayed balance is the **posted** prepaid ledger. xAI posts spend deductions to the ledger at billing-cycle
close (ledger entries are keyed by billing period), so mid-cycle the ledger balance can be higher than the Console's
live remaining credit by the current cycle's not-yet-posted spend. Live verification on a real account confirmed this:
posted balance ≈ live remaining + current-cycle spend.

## Display

The menu card shows the prepaid balance in US dollars. The inline dashboard shows the last 30 days of daily platform
spend with today/30-day totals. When xAI reports its analytics cardinality cap (`limitReached`), the history is labeled
"Last 30 days (partial)" and the snapshot is marked estimated instead of exact. Prepaid money is not a quota, so no
session or weekly meters are synthesized.

The same daily spend series is published into Settings → Usage & Spend and Overview as vendor-metered USD. The prepaid
ledger balance is remaining credit and is never treated as spend.

## CLI Usage

```bash
codexbar --provider xai
```

## Troubleshooting

- A `401` or `403` means xAI rejected the Management API key. Confirm the key was created under Settings > Management
  Keys and has the billing read ACLs; inference keys never work.
- A `404` usually means the team ID is wrong or the key belongs to a different team.
- A usage-history failure does not suppress an otherwise valid balance; the card keeps the balance and drops the chart.
- Organization-scoped management keys must still supply the explicit team ID to bill against.

## Sources

- [Management API guide](https://docs.x.ai/developers/management-api-guide)
- [Billing REST reference](https://docs.x.ai/developers/rest-api-reference/management/billing)
