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
2. Fallback: legacy `GET https://api.openai.com/v1/dashboard/billing/credit_grants` for normal API keys that cannot access organization usage.

## Menu display

- Admin API data renders inline Today/7d/30d KPIs plus a compact 30-day spend chart.
- The inline usage card opens a hosted chart submenu with daily spend, token, and request trends plus selected-day detail.
- Legacy balance data keeps the older available/used credit summary and does not show organization graphs.

## Notes

- Costs are the source of truth for financial totals. Token usage and cost buckets can differ slightly from dashboard billing reconciliation.
- Admin API keys are organization-scoped and cannot be used for normal model inference.
