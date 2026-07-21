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
- **Personal plan windows**: The Qwen Cloud personal plan reports rolling 5-hour and weekly windows instead of a credit pool.

## Editions

Two different products ship under the "token plan" name, and they do not share an API:

| Region | Console | Quota API |
| --- | --- | --- |
| `intl` | `modelstudio.console.alibabacloud.com` | `GetSubscriptionSummary` (team credit pool) |
| `cn` | `bailian.console.aliyun.com` | `GetSubscriptionSummary` (team credit pool) |
| `qwen` | `home.qwencloud.com` | `zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/*` (rolling windows) |

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

## Qwen Cloud personal plan (`region: "qwen"`)

Posts to `https://cs-data.qwencloud.com/data/api.json?product=sfm_bailian&action=IntlBroadScopeAspnGateway`
with the REST path tunneled through the `params` payload. Three endpoints are used:

- `/tokenplan/personal/api/v2/usage` — `per5HourPercentage`, `per1WeekPercentage` (fractions of
  1.0) plus `per5HourResetTime` / `per1WeekResetTime` (epoch ms). Required.
- `/tokenplan/personal/api/v2/subscription` — `specCode` (`lite` / `standard` / `pro`), `status`,
  `remainingDays`, `endTime`. Best-effort.
- `/tokenplan/personal/api/v2/quota-config` — per-tier `five_hour` / `weekly` credit ceilings, joined
  to `specCode` to turn the percentages into credit counts. Best-effort.

Responses nest the payload at `data.DataV2.data.data`. `sec_token` resolves from
`GET https://home.qwencloud.com/tool/user/info.json` (`data.secToken`), the same path the team
edition uses, so cookies alone are sufficient.

## Limitations

- Alibaba Token Plan supports the web-cookie path only; API keys are inference-only credentials and
  return `ConsoleNeedLogin` against the console gateway
- Token cost summaries and automatic status polling are not supported
- The default endpoint is the China mainland Bailian token-plan subscription summary
- Browser cookie auto-import remains macOS-only; on Linux set the cookie source to manual
- `region: "qwen"` is **manual-cookie only on every platform**. Qwen Cloud logs in under its own
  domain with its own ticket cookie (`login_qwencloud_ticket`), which the shared Alibaba browser
  importer does not recognise, so auto-import is rejected up front with a message pointing at the
  console. Paste a `Cookie:` header from
  `https://home.qwencloud.com/billing/subscription/token-plan-individual`.

## Troubleshooting

### "No Alibaba Token Plan session cookies found in browsers"

Log in at `https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan` in Chrome, then refresh CodexBar.

### "Alibaba Token Plan cookie header is invalid"

The pasted header is empty or not a valid Cookie header. Re-copy the request from the Token Plan page after logging in again.

### "Alibaba Token Plan login required"

Your Bailian session is stale. Sign out and back in on the Bailian console, then refresh CodexBar.

### Empty subscription summary

If Bailian returns `TotalCount: 0`, CodexBar keeps the provider visible but does not show a quota window because the account has no active token-plan subscription summary to graph.
