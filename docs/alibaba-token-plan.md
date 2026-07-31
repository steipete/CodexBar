---
summary: "Alibaba Token Plan provider notes: Team and Personal/Solo variants, cookie auth, and setup."
read_when:
  - Adding or modifying the Alibaba Token Plan provider
  - Debugging Alibaba Token Plan cookie import or subscription summary fetching
  - Explaining Alibaba Token Plan setup and limitations to users
---

# Alibaba Token Plan Provider

The Alibaba Token Plan provider tracks Team credits and Personal/Solo rolling-window usage from the Alibaba Cloud console.

## Features

- **Token-plan usage display**: Shows used, total, and remaining token-plan credits when Bailian returns quota totals.
- **Personal/Solo windows**: Shows 5-hour and 7-day usage, reset times, and tier-specific quota totals.
- **Cookie-based auth**: Uses browser cookies or a pasted `Cookie:` header.
- **Expiry awareness**: Shows the nearest token-plan expiration date as the reset time when the subscription summary includes it.

## Setup

1. Open **Settings -> Providers**
2. Enable **Alibaba Token Plan**
3. Choose the matching **Gateway region** Team or Personal/Solo variant
4. Leave **Cookie source** on **Auto** (recommended)

### Manual cookie import (optional)

1. Open the Token Plan page using **Open Token Plan** in settings
2. Copy a `Cookie:` header from the quota request in your browser's Network tab. For Personal/Solo, use the
   `.../tokenplan/personal/api/v2/usage` request so the header is scoped to the quota host.
3. Paste it into **Alibaba Token Plan -> Cookie source -> Manual**

## How it works

- Team variants fetch `GetSubscriptionSummary` from the selected international or mainland console and parse the
  credit pool without probing Personal endpoints.
- Personal/Solo variants fetch `usage`, `subscription`, and `quota-config` from the rolling-window API. International
  uses `bailian-singapore-cs.alibabacloud.com`; mainland uses `bailian-cs.console.aliyun.com`.
- Browser cookies are rebuilt independently for the dashboard and quota hosts. Personal/Solo requests use the
  quota-host cookie header. The dashboard `sec_token` is resolved best-effort and appended when available
  (some accounts get `BailianGateway.Workspace.NotAuthorised` without it); requests still proceed without it.
- Config region values are `intl` and `cn` for Team, or `intl-personal` and `cn-personal` for Personal/Solo.
- Supports `ALIBABA_TOKEN_PLAN_HOST` and `ALIBABA_TOKEN_PLAN_QUOTA_URL` for testing endpoint overrides

## Limitations

- Alibaba Token Plan currently supports the Bailian web-cookie path only
- API-key auth, token cost summaries, and automatic status polling are not supported
- Live provider auth is not exercised by the test suite; endpoint changes rely on reporter confirmation after release

## Troubleshooting

### "No Alibaba Token Plan session cookies found in browsers"

Log in at `https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan` in Chrome, then refresh CodexBar.

### "Alibaba Token Plan cookie header is invalid"

The pasted header is empty or not a valid Cookie header. Re-copy the request from the Token Plan page after logging in again.

### "Alibaba Token Plan login required"

Your Bailian session is stale. Sign out and back in on the Bailian console, then refresh CodexBar.

### Empty subscription summary

If Bailian returns `TotalCount: 0`, CodexBar keeps the provider visible but does not show a quota window because the account has no active token-plan subscription summary to graph.
