# Cost reporting periods

The menu's **History window** supports rolling days, **Month to date**, and **All**. Usage & Spend uses the same period model and keeps its own range selection. Existing saved day counts retain their rolling windows; the dashboard's former All selection migrates to All available history.

Month to date starts at midnight on the first day of the current month and includes today. It uses the pinned cost-bucketing time zone from Settings, falling back to the current local zone. Calendar arithmetic handles leap years and 23/25-hour daylight-saving days. Local log scans reuse Gregorian calendars and the latest day interval for up to eight time zones; crossing a day boundary or changing zones resolves the day again without changing stored cost-cache identities. Each operation resolves its window again, and cache identities include the selection, dates, and time zone.

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

Claude cache updates reconcile transcript rows once per load and reuse that ordered result for cached daily totals and the report. Winner precedence, report ordering, and cache invalidation remain unchanged; separate reporting windows still retain their own rows.

Claude and Vertex cache saves reuse encoded transcript fragments when their metadata bytes and row contents are unchanged. Each cache URL has independent fragments; removed files are discarded and the bounded in-memory memo can be evicted without changing saved JSON or report results. Key ordering and escaping still come from the JSON encoder.
