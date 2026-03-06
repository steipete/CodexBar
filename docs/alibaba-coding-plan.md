---
summary: "Alibaba Coding Plan provider data sources: API key auth, Model Studio quota endpoint, and intl/cn region fallback."
read_when:
  - Debugging Alibaba Coding Plan API key handling or quota parsing
  - Updating Alibaba Coding Plan endpoints or region behavior
  - Adjusting Alibaba Coding Plan provider UI/menu behavior
---

# Alibaba Coding Plan provider

Alibaba Coding Plan supports both browser-session and API-key paths.

## Cookie sources (web mode)
1) Automatic browser import (Model Studio/Bailian cookies).
2) Manual cookie header from Settings.
3) Environment variable `ALIBABA_CODING_PLAN_COOKIE`.

When the RPC endpoint returns `ConsoleNeedLogin`, CodexBar treats it as invalid credentials and falls back to web mode in `auto` source mode.

## Token sources (fallback order)
1) Config token (`~/.codexbar/config.json` -> `providers[].apiKey` for provider `alibaba`).
2) Environment variable `ALIBABA_CODING_PLAN_API_KEY`.

## Region + endpoint behavior
- International host: `https://modelstudio.console.alibabacloud.com`
- China mainland host: `https://bailian.console.aliyun.com`
- Quota request path:
  - `POST /data/api.json?action=zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2&product=broadscope-bailian&api=queryCodingPlanInstanceInfoV2`
- Region is selected in Preferences -> Providers -> Alibaba Coding Plan -> Gateway region.
- Auto fallback behavior:
  - If International fails with credential/host-style API errors, CodexBar retries China mainland once.

## Overrides
- Override host base: `ALIBABA_CODING_PLAN_HOST`
  - Example: `ALIBABA_CODING_PLAN_HOST=modelstudio.console.alibabacloud.com`
- Override full quota URL: `ALIBABA_CODING_PLAN_QUOTA_URL`
  - Example: `ALIBABA_CODING_PLAN_QUOTA_URL=https://example.com/data/api.json?action=...`

## Request headers
- `Authorization: Bearer <api_key>`
- `x-api-key: <api_key>`
- `X-DashScope-API-Key: <api_key>`
- `Content-Type: application/json`
- `Accept: application/json`

## Parsing + mapping
- Plan name (best effort):
  - `codingPlanInstanceInfos[].planName` / `instanceName` / `packageName`
- Quota windows (from `codingPlanQuotaInfo`):
  - `per5HourUsedQuota` + `per5HourTotalQuota` + `per5HourQuotaNextRefreshTime` -> primary (5-hour)
  - `perWeekUsedQuota` + `perWeekTotalQuota` + `perWeekQuotaNextRefreshTime` -> secondary (weekly)
  - `perBillMonthUsedQuota` + `perBillMonthTotalQuota` + `perBillMonthQuotaNextRefreshTime` -> tertiary (monthly)
- Each window maps to `usedPercent = used / total * 100` (bounded to valid range).

## Dashboard links
- International console: `https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=globalset#/efm/coding_plan`
- China mainland console: `https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan`

## Key files
- `Sources/CodexBarCore/Providers/Alibaba/AlibabaCodingPlanProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Alibaba/AlibabaCodingPlanUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/Alibaba/AlibabaCodingPlanUsageSnapshot.swift`
- `Sources/CodexBar/Providers/Alibaba/AlibabaCodingPlanProviderImplementation.swift`
