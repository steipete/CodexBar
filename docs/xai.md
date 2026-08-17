---
summary: "xAI provider: Management API prepaid spend, plus SuperGrok OAuth and grok.com browser-token usage."
read_when:
  - Configuring xAI platform usage
  - Debugging xAI Management API requests
  - Adding SuperGrok OAuth or grok.com browser tokens
---

# xAI Provider

CodexBar can read two separate xAI billing surfaces. They do not share credentials or identity:

- **Management API** — developer-platform prepaid ledger via a Management API key + team ID.
- **SuperGrok OAuth / web** — consumer SuperGrok / X Premium+ subscription credits via a browser token or grok.com cookies.

This provider is still separate from the [Grok provider](grok.md). Enabling both SuperGrok paths at once can show the same subscription quota twice. SuperGrok tokens never call `management-api.x.ai`.

## Authentication

Settings → Providers → xAI has a usage-source picker: Auto, Management API, SuperGrok OAuth, or Browser cookies. Auto uses the Management API when a key and team ID are present, then SuperGrok OAuth, then cookies.

### Management API

Create a **Management API key** in the [xAI Console](https://console.x.ai) under Settings > Management Keys, then add
it together with your **team ID**. Inference API keys are not accepted by the
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

### SuperGrok OAuth

Paste a SuperGrok bearer token into xAI token accounts, or set `XAI_OAUTH_TOKEN`. CodexBar classifies `xai-…` as a Management key, `Cookie:` / `name=value` as a web session, and other bearers as SuperGrok OAuth.

Chrome-only cookie import from `grok.com` is available for the web source (user-initiated / app runtime only). grok.com gRPC billing often rejects cookie-only sessions that lack a browser-held WKE keypair; paste an OAuth token when that happens.

An off-by-default toggle can read `~/.grok/auth.json` from `grok login`. That file is read-only. CodexBar never refreshes or writes it, and never copies Grok-provider identity onto the xAI card.

```bash
export XAI_OAUTH_TOKEN="..."
```

## Data Source

Management API requests:

- `GET https://management-api.x.ai/v1/billing/teams/{team_id}/prepaid/balance`
- `POST https://management-api.x.ai/v1/billing/teams/{team_id}/usage` with a daily, USD-summed analytics query for the
  last 30 days (UTC), as best-effort history enrichment.

Both Management API requests use `Authorization: Bearer <management key>`.

SuperGrok OAuth requests:

- `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with `Authorization: Bearer <token>` and `x-xai-token-auth: xai-grok-cli`
- Plan badge comes from billing `subscriptionTier` (`config` first, then the envelope): SuperGrok vs SuperGrok Heavy. SuperGrok Heavy omits `creditUsagePercent`; that is unknown usage, not 0%.

The web source may fall back to grok.com billing with a Chrome session cookie. Token refresh is not implemented; an expired SuperGrok token is an auth error.

Usage Dashboard opens [grok.com usage](https://grok.com/?_s=usage) for SuperGrok OAuth and cookie sessions, and [console.x.ai](https://console.x.ai) for Management API snapshots.

The balance endpoint reports an inverted ledger in string USD cents — a $10 top-up appears as `"-1000"` — so the
remaining balance is the negated cent value. A response without a parseable total is treated as an error, never as a
$0.00 balance.

The displayed balance is the **posted** prepaid ledger. xAI posts spend deductions to the ledger at billing-cycle
close (ledger entries are keyed by billing period), so mid-cycle the ledger balance can be higher than the Console's
live remaining credit by the current cycle's not-yet-posted spend. Live verification on a real account confirmed this:
posted balance ≈ live remaining + current-cycle spend.

## Display

The Management API menu card shows the prepaid balance in US dollars. The inline dashboard shows the last 30 days of daily platform spend with today/30-day totals. When xAI reports its analytics cardinality cap (`limitReached`), the history is labeled
"Last 30 days (partial)" and the snapshot is marked estimated instead of exact. Prepaid money is not a quota, so no
session or weekly meters are synthesized.

SuperGrok OAuth/web shows subscription credit usage (Weekly/Monthly/Credits) with a SuperGrok plan badge. It does not synthesize a prepaid ledger or attach Grok CLI email/org fields.

## CLI Usage

```bash
codexbar --provider xai
```

## Troubleshooting

- A `401` or `403` means xAI rejected the Management API key. Confirm the key was created under Settings > Management Keys and has the billing read ACLs; inference keys never work.
- A `404` usually means the team ID is wrong or the key belongs to a different team.
- A usage-history failure does not suppress an otherwise valid balance; the card keeps the balance and drops the chart.
- Organization-scoped management keys must still supply the explicit team ID to bill against.
- A `401` or `403` on SuperGrok OAuth means the browser token expired or is not eligible. Paste a fresh token, or re-run `grok login` and enable the Grok CLI credential toggle.
- Cookie-only grok.com billing can fail with a WKE / no-credentials error. Use SuperGrok OAuth instead of cookies.
- Enabling xAI SuperGrok OAuth and the Grok provider together can show the same subscription quota on two cards.

## Sources

- [Management API guide](https://docs.x.ai/developers/management-api-guide)
- [Billing REST reference](https://docs.x.ai/developers/rest-api-reference/management/billing)
