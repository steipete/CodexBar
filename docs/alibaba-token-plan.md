---
summary: "Alibaba Token Plan provider notes: Bailian cookie auth, subscription summary endpoint, and setup."
read_when:
  - Adding or modifying the Alibaba Token Plan provider
  - Debugging Alibaba Token Plan cookie import or subscription summary fetching
  - Explaining Alibaba Token Plan setup and limitations to users
---

# Alibaba Token Plan Provider

The Alibaba Token Plan provider tracks Bailian token-plan credits from the Alibaba Cloud console.

## Features

- **Token-plan usage display**: Shows used, total, and remaining token-plan credits when Bailian returns quota totals.
- **Cookie-based auth**: Uses browser cookies or a pasted `Cookie:` header.
- **Expiry awareness**: Shows the nearest token-plan expiration date as the reset time when the subscription summary includes it.

## Setup

1. Open **Settings -> Providers**
2. Enable **Alibaba Token Plan**
3. Leave **Cookie source** on **Auto** (recommended)

### Manual cookie import (optional)

1. Open `https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan`
2. Copy a `Cookie:` header from your browser's Network tab
3. Paste it into **Alibaba Token Plan -> Cookie source -> Manual**

## How it works

- Fetches `POST https://bailian.console.aliyun.com/data/api.json?action=GetSubscriptionSummary&product=BssOpenAPI-V3&_tag=`
- Sends form-encoded fields for `product=BssOpenAPI-V3`, `action=GetSubscriptionSummary`, `region=cn-beijing`, and `params={"ProductCode":"sfm_tokenplanteams_dp_cn"}`
- Uses Alibaba/Bailian login cookies, with `sec_token` added when it can be resolved from the dashboard page
- Parses `TotalValue`, `TotalSurplusValue`, `TotalCount`, and `NearestExpireDate` from the subscription summary response
- Supports `ALIBABA_TOKEN_PLAN_HOST` and `ALIBABA_TOKEN_PLAN_QUOTA_URL` for testing endpoint overrides

## Limitations

- Alibaba Token Plan currently supports the Bailian web-cookie path only
- API-key auth, token cost summaries, and automatic status polling are not supported
- The default endpoint is the China mainland Bailian token-plan subscription summary

## Troubleshooting

### "No Alibaba Token Plan session cookies found in browsers"

Log in at `https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan` in Chrome, then refresh CodexBar.

### "Alibaba Token Plan cookie header is invalid"

The pasted header is empty or not a valid Cookie header. Re-copy the request from the Token Plan page after logging in again.

### "Alibaba Token Plan login required"

Your Bailian session is stale. Sign out and back in on the Bailian console, then refresh CodexBar.

### Empty subscription summary

If Bailian returns `TotalCount: 0`, CodexBar keeps the provider visible but does not show a quota window because the account has no active token-plan subscription summary to graph.
