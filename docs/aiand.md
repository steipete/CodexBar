---
summary: "ai& provider: API key setup and 30-day spend summed from the request logs API."
read_when:
  - Configuring ai& usage
  - Debugging ai& request-log fetches
---

# ai& Provider

CodexBar reads organization spend from ai&'s documented request-log API. ai& (aiand.com) is an OpenAI/Anthropic-compatible
inference gateway that can back Claude Code, Codex CLI, and opencode (all three have dedicated integration guides in
the ai& docs).

## Authentication

Create an API key in the [ai& console](https://console.aiand.com) (Settings → API Keys → Create). Keys use the `sk-`
prefix and are shown once at creation time. Add the key in CodexBar Settings → Providers → ai&.

You can also set the environment variable:

```bash
export AIAND_API_KEY="..."
```

Or configure it through the CLI:

```bash
printf '%s' "$AIAND_API_KEY" | codexbar config set-api-key --provider aiand --stdin
```

## Data Source

CodexBar requests:

- `GET https://api.aiand.com/logs?range=30days&limit=100`, following `next_after`/`next_after_id` cursor pagination
  (both cursors are always passed together, as the docs require) for up to 10 pages per refresh.

Spend is the sum of each log row's `cost` field, parsed as decimal strings — never floating point — in the
organization's billing currency (`currency` per row: USD or JPY). Requests use `Authorization: Bearer <AIAND_API_KEY>`.
CodexBar does not read ai& browser cookies, console sessions, or inference prompts; only per-request cost/currency
metadata from the log rows is used.

Why the log endpoint: as of 2026-07-17 the documented `cost_usd` field is missing from live
`GET /analytics/summary` responses (the endpoint returns only request/token counts and a token timeseries), and
`/analytics/metrics` has no cost series either. `/logs` matches its documentation exactly and is the only public
endpoint that reports cost, so CodexBar sums spend from it.

## Display

The menu shows the last 30 days of organization spend, in the organization's billing currency, as an API-spend row.
ai& bills prepaid credits with no quota windows, so no session or weekly meters are shown. The remaining credit balance
is only available in the ai& console; the public API does not expose it.

Notes:

- The billing currency is read from the log rows themselves — CodexBar never assumes a currency. If the organization
  made no requests in the window there are no rows and no currency source, so no spend row is shown at all.
- ai& retains request logs for 30 days, which is exactly the summed window.
- CodexBar reads at most 10 pages (1,000 requests) per refresh. If the organization has more requests in the window,
  the row is labeled "Last 30 days (partial)" and covers only the newest 1,000 requests — there is no silent
  truncation.
- If log rows ever disagree on currency, only rows matching the newest row's currency are summed.
- API keys are organization-scoped: every key in the same organization reports the same org-wide spend.

## CLI Usage

```bash
codexbar usage --provider aiand
```

`ai&` and `ai-and` also work as provider aliases.

## Troubleshooting

- A `401` means ai& rejected the API key; create a new key in the console (keys are shown only once).
- A `402` means the organization is out of prepaid credits; top up at console.aiand.com.
- A `429` means the per-minute rate limit was hit; CodexBar retries on the next refresh cycle.
- A "(partial)" period label means the 10-page cap was hit; the total covers the newest 1,000 requests only.

## Sources

- [Request Logs](https://docs.aiand.com/analytics/logs/)
- [Authentication](https://docs.aiand.com/authentication/)
- [Credits & Top-Up](https://docs.aiand.com/billing/credits/)
