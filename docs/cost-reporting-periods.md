# Cost reporting periods

## Conversation usage details

In a cost submenu with session records, click a conversation to open the shared Sessions inspector in
Usage & Spend and inspect its input, cached input, uncached input, output,
reasoning, requests, estimated cost, and per-model breakdown. The search icon next to Conversations opens
the same inspector for all conversations retained in that menu's current account and history window.
The Sessions section in Usage & Spend reuses this component and selects providers/accounts separately;
identical session IDs from different sources remain isolated. Sources provide `CostUsageSessionBreakdown`
records with normalized token buckets; absent session data, turn records, and prices stay unavailable.
A provider appearing in the app does not by itself mean its backend supplies session records.
Search matches conversation names or IDs. Sort by recent activity, token count, or cost in either
direction; unknown values stay last.

Expand a turn to inspect the input, cache hits, output, reasoning, request count, and estimated spend
recorded during that turn in the selected history window. Model requests expand into individual
de-duplicated usage records with their recorded or estimated prices. Local native tool activity can
also be expanded for that turn, including names, outcomes, durations, and available input/output.
Tools have no separate token or monetary cost in this log; their content can contribute to later
model requests. This view does not estimate a tool's price from its duration or output length.

Messages sharing a turn cannot be priced separately. Missing turn ownership or older history without
request records appears as unattributed usage; unavailable prices remain unknown. Requests outside the
selected period and usage belonging to separate subagent sessions are not added to a parent's turn.
For the Codex adapter, automatic approval-review sessions can appear alongside user-created
conversations because its scanner reads local Codex session logs. A recorded zero-dollar amount does not imply zero tokens.

The inspector uses the existing cost snapshot and preferred currency. Cached input is a subset of input;
reasoning is a subset of output. Unavailable counters or prices remain unavailable rather than becoming
zero. Hide personal information also masks the browser's names and prevents search from revealing them.

Ordinary refreshes retain session summaries and a source handle, without building request-detail arrays.
Selecting a native Codex session reads only that session's existing SQLite rows. The read is limited to
5,000 requests, 8 MiB of request payload, 1 MiB of file metadata, and 5,000 day/model aggregates with
1 MiB of model names. Persisted pricing metadata has a separate 1 MiB limit. If a limit is exceeded or
the source or its catch-up checkpoint has changed, the summary stays visible and request details are unavailable; totals are never
silently truncated. Changing selection cancels the previous read, and closing the inspector releases its
request details. Session accounting keeps the source snapshot's reporting period even when a chart day
is selected. No additional history store is created.

## History windows

The menu's **History window** supports rolling days, **Month to date**, and **All**. Usage & Spend uses the same period model and keeps its own range selection. Existing saved day counts retain their rolling windows; the dashboard's former All selection migrates to All available history.

Usage & Spend groups ranges longer than 45 reporting days by week, and ranges longer than 180 days by month. Select a bucket to inspect its days, then a day with hourly records to inspect individual hours. Daily scrolling keeps whole reporting days visible across daylight-saving changes. Hour labels use a shared 24-hour clock and include UTC offsets in the inspector to distinguish repeated hours. The legend can isolate an account without changing dashboard totals. It shows sources with recorded amounts in the displayed range, drilled interval, or hourly day, including recorded zero-dollar amounts. Sources without priced records in that scope are omitted; account labels and colors stay stable. Legend chips and inspector amounts wrap in narrow windows. Daily inspection only selects existing buckets, so plot padding cannot produce an adjacent date with an empty inspector.

Chart summaries describe **recorded spend**, not an authoritative bill. A priced day alongside an unpriced day keeps the source and period totals unavailable. Missing hours remain distinct from recorded zero, incomplete sources retain their lower-bound marker, and an empty daily chart shows no usage only when coverage proves zero spend for the selected sources and interval. Aggregates that cannot be represented remain unavailable; valid individual records stay in the accounting model.

Month to date starts at midnight on the first day of the current month and includes today. It uses the pinned cost-bucketing time zone from Settings, falling back to the current local zone. Calendar arithmetic handles leap years and 23/25-hour daylight-saving days. Local log scans reuse Gregorian calendars and the latest day interval for up to eight time zones; crossing a day boundary or changing zones resolves the day again without changing stored cost-cache identities. Each operation resolves its window again, and cache identities include the selection, dates, and time zone.

Menu cost and token charts retain one slot for every calendar day in the selected window, for every provider. A missing day is zero only after the history scan covers that window; incomplete scans and recorded unpriced costs remain unknown. OpenAI and Mistral keep their fixed UTC billing-day calendars; local history follows the selected bucket time zone.

The menu selection also supplies the default for `codexbar cost`, the HTTP `/cost` endpoint, and widget cost summaries. The widget metric is named **Cost**; its displayed period comes from the app's snapshot. Explicit CLI options override the saved selection:

```sh
codexbar cost --period month-to-date --json
codexbar cost --period all --json
codexbar cost --days 7 --json
```

`--days N` always selects a rolling window, even alongside `--period`. Rolling windows accept 1–365 days and default to 30 on installations without a saved selection. JSON includes `reportingPeriod`, `historyLabel`, and period totals under `totals`; the existing `last30DaysTokens` and `last30DaysCostUSD` compatibility fields retain their documented meaning.

The existing host-summary protocol (`--remote` and `--summary-only`) remains limited to 1–365 days. When All is selected, use an explicit `--days N` for those modes.

All reads the available source history, including local logs older than a year. Missing or deleted logs cannot be recovered, provider APIs can impose their own history limits, and incomplete scans remain marked as incomplete. Local priority metadata is reconciled only for recorded days, without a fixed earliest-year cutoff or empty-day cache entries. This is not a permanent ledger or a lifetime bill since installation. The separate token-activity heatmap still covers one year.

Cursor's quota bars keep the billing-cycle dates reported by Cursor. Calendar-month cost is a complementary view of dated usage events; it does not reinterpret a mid-month billing-cycle allowance as a calendar-month quota.

Claude cache updates reconcile transcript rows once per load and reuse that ordered result for cached daily totals and the report. Duplicate winners reference the existing transcript rows until the final ordered result is assembled, reducing temporary memory use for large histories. Winner precedence, report ordering, and cache invalidation remain unchanged; separate reporting windows still retain their own rows.

Within each transcript scan or cache decode, repeated session IDs and model names share string storage without changing their UTF-8 spelling or the saved JSON.

Claude and Vertex reserve the final transcript row count during cache decoding and parsed-row assembly, reducing retained spare capacity without changing cache bytes or report ordering.

Claude and Vertex cache saves reuse encoded transcript fragments when their metadata bytes and row contents are unchanged. The bounded memo retains byte ranges in the previous artifact instead of encoded values; saves stream those ranges and newly encoded files into a replacement artifact. Reuse requires the same device, inode, size, and nanosecond modification time. Each cache URL has independent fragments; removed files are discarded and the memo can be evicted without changing saved JSON or report results. Transcript-cache loads use mapped input that is released after decoding. Key ordering and escaping still come from the JSON encoder.
