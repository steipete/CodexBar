---
summary: "OpenAI API provider: Admin API key usage/cost graphs and legacy balance fallback."
read_when:
  - Updating OpenAI API Platform usage or cost display
  - Debugging OPENAI_ADMIN_KEY or OPENAI_API_KEY behavior
---

# OpenAI API provider

CodexBar's OpenAI API provider targets the API Platform organization dashboard, not ChatGPT/Codex subscription limits.

## Data sources

1. Preferred: `OPENAI_ADMIN_KEY` or configured key with Admin API access.
   - `GET https://api.openai.com/v1/organization/costs`
   - `GET https://api.openai.com/v1/organization/usage/completions`
   - Daily buckets use `bucket_width=1d`, costs are grouped by `line_item`, and completion usage is grouped by `model`.
   - Optional project scoping comes from `OPENAI_PROJECT_ID` or `providers[].workspaceID` for `openai`.
     Project-scoped requests add `project_ids=<project>` to both Admin API endpoints.
2. Fallback: legacy `GET https://api.openai.com/v1/dashboard/billing/credit_grants` for normal API keys that cannot access organization usage.

## Setup

Store a key in the shared app/CLI config:

```bash
printf '%s' "$OPENAI_ADMIN_KEY" | codexbar config set-api-key --provider openai --stdin
```

Settings → Providers → OpenAI writes the same `~/.codexbar/config.json` field. `OPENAI_ADMIN_KEY` is preferred over
`OPENAI_API_KEY` because it unlocks organization costs and usage; a normal API key only supports the legacy balance
fallback.

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
API failures do not fall back to the legacy billing endpoint, because that endpoint is not project-filtered.

## Menu display

- Admin API data renders inline Today/7d/configured-window KPIs plus a compact spend chart.
- The inline usage card opens a hosted chart submenu with daily spend, token, and request trends plus selected-day detail.
- Top model and top spend labels come from the configured completion/cost buckets when the Admin API returns them.
- Legacy balance data keeps the older available/used credit summary and does not show organization graphs.
- Project-scoped Admin API data labels the account as `Admin API: <project>` and the organization line as
  `Project: <project>`.

## Notes

- Costs are the source of truth for financial totals. Token usage and cost buckets can differ slightly from dashboard billing reconciliation.
- Admin API keys are organization-scoped and cannot be used for normal model inference.
