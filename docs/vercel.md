---
summary: "Vercel AI Gateway team credits through an AI Gateway key, or a personal budget through an optional Vercel access token."
read_when:
  - Setting up or modifying the Vercel AI Gateway provider
---

# Vercel AI Gateway

Enable **Vercel AI Gateway** in Settings → Providers. The provider shows one of two views:

- **Team credits** (default): enter an AI Gateway API key, or set `AI_GATEWAY_API_KEY`.
- **Personal budget** (optional): enter a Vercel access token and Team ID, or set `VERCEL_ACCESS_TOKEN` and
  `VERCEL_TEAM_ID`. When a token is configured, it replaces the team-credit view.

Values entered in Settings are saved in CodexBar's local config file. Use `codexbar usage --provider vercel` to fetch.

The plugin host binds one authentication secret per manifest, so each view is a separate bundled script with its own
secret and origin: `vercel.js` sends only the AI Gateway key to `ai-gateway.vercel.sh`, and `vercel-budget.js` sends only
the access token to `api.vercel.com`. Neither credential can reach the other origin. Neither script reads Vercel CLI
credentials, switches teams, inspects Keychain, or queries the metered Custom Reporting API.

## Team credits

`vercel.js` reads `GET https://ai-gateway.vercel.sh/v1/credits` with bearer authentication.
It displays the key's **team-wide remaining USD balance** and **lifetime USD spend**, from the documented
`balance` and `total_used` decimal strings. Zero and negative balances are preserved. Missing or malformed
values fail the refresh; they do not become zero. The shared HTTP host bounds requests and retries transient failures.

This endpoint has no spending limit or reset date, so the view shows amounts without a percentage bar,
reset countdown, or billing-period estimate. Select the appropriate team's API key to change scope.

## Personal budget

`vercel-budget.js` reads `GET /v2/user` for the token's user ID, then
`GET /ai-gateway/budgets/list?teamId=…&scopeType=user` with `limit=200`, following `nextCursor` for up to 20 pages
with the same team on every page. The budget is matched by user ID; a custom budget takes precedence over an inherited
default. The card shows spend, limit, and remaining personal allowance. Daily, weekly, and monthly
budgets reset at the documented UTC boundaries (weekly on Monday); a cumulative (`none`) budget has no reset date.

A missing personal budget is shown as not configured, never as zero spend. HTTP failures, malformed values, ambiguous
matches, invalid active/archive flags, repeated cursors, and incomplete pagination fail the refresh without publishing a partial budget. Every team
role except Contributor can read budgets.

The remaining personal allowance is not the spendable amount: team, project, and key budgets, or the team balance, can
stop requests first. Only keys with **User** spend attribution count toward a personal budget, and BYOK spend does not.

Vercel does not participate in plan-utilization history or burn-down widgets: a personal budget belongs to a user within
one team, which a provider-wide history bucket cannot represent. Existing history is preserved but not extended.

Sources: [REST credit API](https://vercel.com/docs/ai-gateway/sdks-and-apis/rest-api#check-credit-balance),
[usage semantics](https://vercel.com/docs/ai-gateway/observability-and-spend/usage),
[budgets](https://vercel.com/docs/ai-gateway/observability-and-spend/budgets),
[list budgets API](https://vercel.com/docs/rest-api/ai-gateway/list-ai-gateway-budgets),
[spend attribution](https://vercel.com/docs/ai-gateway/authentication-and-byok/api-keys#spend-attribution), and
[reporting pricing](https://vercel.com/docs/ai-gateway/observability-and-spend/custom-reporting#pricing).
