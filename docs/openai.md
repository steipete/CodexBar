---
summary: "OpenAI API provider: Admin API key daily graphs, per-minute live usage, and legacy balance fallback."
read_when:
  - Updating OpenAI API Platform usage or cost display
  - Updating the OpenAI Live Usage window
  - Debugging OPENAI_ADMIN_KEY or OPENAI_API_KEY behavior
---

# OpenAI API provider

CodexBar's OpenAI API provider targets the API Platform organization dashboard, not ChatGPT/Codex subscription limits.

The bundled `openai.js` plugin is authoritative on QuickJS and JavaScriptCore. Swift retains settings and the typed
usage-card adapter; the script supplies daily history, source labels, project scoping, and legacy billing fallback.

## Data sources

1. Preferred: `OPENAI_ADMIN_KEY` or configured key with Admin API access.
   - `GET https://api.openai.com/v1/organization/costs`
   - `GET https://api.openai.com/v1/organization/usage/completions`
   - Daily buckets use `bucket_width=1d`, costs are grouped by `line_item`, and completion usage is grouped by `model`.
   - Optional project scoping comes from `OPENAI_PROJECT_ID` or `providers[].workspaceID` for `openai`.
     Project-scoped requests add `project_ids=<project>` to both Admin API endpoints.
2. Best-effort fallback: legacy `GET https://api.openai.com/v1/dashboard/billing/credit_grants` for older user API
   keys that cannot access organization usage. This endpoint is not part of OpenAI's current public API reference.

## Setup

Store a key in the shared app/CLI config:

```bash
printf '%s' "$OPENAI_ADMIN_KEY" | codexbar config set-api-key --provider openai --stdin
```

Settings → Providers → OpenAI writes the same `~/.codexbar/config.json` field. `OPENAI_ADMIN_KEY` is preferred over
`OPENAI_API_KEY` because it unlocks organization costs and usage; a normal API key only supports the legacy balance
fallback. Selected token accounts take precedence over both environment keys and the configured key. Each
credential keeps its own manual organization rate limits; Settings edits the selected account's list and identifies
that account, or edits the provider key's list when no token account is selected.

Project service-account keys are project-scoped credentials for API workloads. They are not organization Admin API
keys, so they cannot read the organization usage and cost endpoints used by CodexBar. Configure an organization Admin
API key instead; CodexBar reports this distinction when a project or service-account key is rejected.

To scope Admin API usage to a project, set the OpenAI Project ID field in Settings or add `workspaceID` to the `openai`
provider config:

```json
{
  "id": "openai",
  "apiKey": "<OPENAI_ADMIN_KEY>",
  "workspaceID": "proj_..."
}
```

Project scoping is tied to the configured Admin API key. Selected OpenAI token accounts intentionally scrub
`OPENAI_PROJECT_ID`/`workspaceID` so one account cannot inherit another account's project filter. Project-scoped Admin
API failures with a configured Admin key or `OPENAI_ADMIN_KEY` do not fall back to the legacy billing endpoint, because
that endpoint is not project-filtered. The legacy `OPENAI_API_KEY` environment path retains its existing balance fallback.

## Menu display

- Admin API data renders a **Tokens / min · last hour** chart above the daily spend dashboard, with the latest reported minute, peak, and (when configured) the highest manual org-limit utilization across all models. Pending minutes are shaded. Click **Live Usage…** to open the detailed window.
- **Settings → Providers → OpenAI → Tokens per minute** is on by default. Each refresh adds one `bucket_width=1m`, `group_by=model`, `group_by=batch`, `limit=60` completion-usage request, with the same project scope. Disable it to omit the chart and minute request (`OPENAI_LIVE_MINUTES=0`; enabled is `60`). A failed minute request leaves the daily data usable.
- The menu bar layout editor offers an optional **Tokens / min** value such as `49M/min`; default layouts are unchanged.
- Daily Admin API data renders inline Today/7d/configured-window KPIs plus a compact spend chart.
- The inline usage card opens a hosted chart submenu with daily spend, token, and request trends plus selected-day detail.
- Top model and top spend labels come from the configured completion/cost buckets when the Admin API returns them.
- Legacy balance data keeps the older available/used credit summary and does not show organization graphs.
- Project-scoped Admin API data labels the account as `Admin API: <project>` and the organization line as
  `Project: <project>`.

## Live usage

Choose **Live Usage** in the OpenAI provider menu to open a separate, on-demand window. It defaults to **All models**;
choose a specific model in the picker or table to inspect its throughput. The filter is not saved across app launches.
The 15-minute, 1-hour (default), and 6-hour ranges show tokens per minute, recent and peak throughput, token totals,
and request counts. Batch API traffic is included in charts, totals, and tooltips, but excluded from TPM/RPM
**% of limit** because it has a [separate rate-limit pool](https://developers.openai.com/api/docs/guides/batch#rate-limits).
Cached input is a subset of input tokens; total tokens are input plus output.

The window reads `GET /v1/organization/usage/completions` with `bucket_width=1m`, `group_by=model`, and `group_by=batch`, following
pagination and filling missing minutes on a regular grid. This covers completions/responses usage only; embeddings, images,
and separate audio endpoints are not included. It requires an organization Admin API key (`sk-admin-…`), even when
the daily card can fall back to a legacy balance. Credentials and optional `project_ids` scoping use the same settings
and selected-account rules as the daily view.

While open, the window polls every 30 seconds and supports Refresh (⌘R). Rate limiting doubles the polling interval
up to 5 minutes; a successful fetch restores 30 seconds. Closing the window stops polling. Failed requests keep the
last successful snapshot visible with an inline error. The data is near-realtime: buckets commonly arrive 2–3 minutes late.
**Latest** shows the newest complete minute with any reported tokens across all models, searched within the last
10 complete minutes. Its timestamp identifies that reporting frontier; the five-minute average ends there too.
Selecting a model keeps the same frontier, so a model idle at that minute correctly shows zero. If all ten minutes
are empty, the last complete minute is used so genuine idle periods show zero. Minutes after the frontier,
including the in-progress minute, are shaded as **reporting…**, rather than drawn as zero bars. This is organization usage across all API keys and harnesses within the selected
project scope, or the whole organization when no project is configured.

### Organization rate-limit headroom

Manual organization limits belong to the credential whose organization they describe. Provider-level
`modelRateLimits` describes the provider key (configured `apiKey` or environment key); each token account stores
its own `tokenAccounts.accounts[].modelRateLimits`, with no inheritance from the provider key or other accounts.
Sync keeps an account's limits when an older CodexBar version updates token accounts.
Settings edits the selected account's list and says which credential it applies to. Switching accounts switches
the limits used by Settings and the live menu card; stacked token-account cards use their own account's limits.
Cards whose credential is unknown, such as snapshots from other Macs, show no organization-limit utilization.
The Live Usage window retains the displayed account's limits until the next refresh switches both data and limits.
Edits to that displayed credential's limits update the open window immediately without refetching usage.

The Live Usage window compares each model's latest reported minute and peak tokens per minute (TPM), plus peak
requests per minute (RPM), with **manual organization limits from Settings only**. The single-model view shows
utilization and a dashed chart line when a manual limit is near the plotted range; otherwise it labels the limit
off scale. Without a manual limit it shows **Org limit not set** and a shortcut to Settings. The all-models table
shows manual org limits and peak utilization; the highest-utilization tile considers only models with manual
limits and never combines unrelated model limits. Project-scoped usage (`OPENAI_PROJECT_ID` or `workspaceID`) is
only one project's slice of the organization traffic those limits apply to, so the window, chart, and menu card show
no org-limit utilization or limit tile for project-scoped data. Cached snapshots record their own project scope, so
this holds even after the project setting changes but before a successful refresh.

OpenAI has no organization-level limits endpoint. Per-project limits are **project caps**, not an organization
ceiling: observed organization traffic exceeded every project's cap because traffic was spread across projects.
For context, CodexBar lists active projects with `GET /v1/organization/projects` and reads
`GET /v1/organization/projects/{project_id}/rate_limits`, taking the maximum TPM and RPM independently for each
model across up to **25 active projects**. The table and single-model limit tile show project caps separately;
project caps never drive utilization percentages or chart limit lines. A truncated sample is labeled. Discovery
always covers the organization, even when usage is filtered by `OPENAI_PROJECT_ID` or `workspaceID`.

Use **Limits…** or **Set org limit…** to open Settings → Providers → OpenAI → **Organization rate limits**.
Copy the limits from the [organization Limits page](https://platform.openai.com/settings/organization/limits).
Enter a model ID, positive TPM, and optional positive RPM. The editor accepts numbers such as `40000000`,
`40,000,000`, `40M`, `150k`, and `1.5M`. Invalid edits remain local until valid. Manual entries apply immediately
to an open window. Manual limits and project caps each match exact model IDs first, then a family ID followed by a dated snapshot
suffix (`-YYYY-MM-DD`, or the older `-MMDD`). Thus `gpt-4o-mini` matches `gpt-4o-mini-2024-07-18`, while `gpt-5`
does not match the distinct model `gpt-5-mini` and `gpt-4` does not match `gpt-4o`.

Project caps are fetched when the window opens, then at most every 15 minutes. Refresh refetches them only if the
last attempt is older than 5 minutes. Permission, rate-limit, and network failures leave usage and its polling
backoff untouched; a secondary message exposes the error on hover. Manual limits and the last successful project
caps remain usable. Credentials follow the same Admin-key resolution as live usage.

**% of limit** counts all input, including cached input, plus output: OpenAI's prompt-caching guide states that cached input tokens still count toward TPM limits. Batch API traffic is excluded because it has separate rate limits. The limiter also reserves `max_tokens` up front, so short bursts can still hit limits. Charts and throughput totals continue to include cached input; a filtered chart stacks uncached input, output, and cached input, and its limit line compares against the full stack.
Models that resolve to the same configured limit (an alias and its dated snapshots) share it, and utilization
sums their traffic per minute. Shared pools OpenAI lists across different families are not inferred.

## Notes

- Costs are the source of truth for financial totals. Token usage and cost buckets can differ slightly from dashboard billing reconciliation.
- Admin API keys are organization-scoped and cannot be used for normal model inference.
- Manual organization limits are per credential. Enter limits separately for the provider key and each token account;
  project-scoped usage still suppresses organization-limit utilization.
