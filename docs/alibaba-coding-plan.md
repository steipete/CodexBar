---
summary: "Alibaba Coding Plan provider data sources: browser-session baseline, secondary API mode, and honest quota fallback behavior."
read_when:
  - Debugging Alibaba Coding Plan API key handling or quota parsing
  - Updating Alibaba Coding Plan endpoints or region behavior
  - Adjusting Alibaba Coding Plan provider UI/menu behavior
---

# Alibaba Coding Plan provider

Alibaba Coding Plan supports both browser-session and API-key paths, but the supported baseline is browser-session fetching from the Model Studio/Bailian console. API mode remains secondary and may still be limited by account/region behavior.

## Cookie sources (web mode)
1) Automatic browser import (Model Studio/Bailian cookies).
2) Manual cookie header from Settings.
3) Environment variable `ALIBABA_CODING_PLAN_COOKIE`.

When the RPC endpoint returns `ConsoleNeedLogin`, CodexBar treats that as a console-session requirement. In API mode it is surfaced as an explicit API-path limitation; in `auto` mode fallback remains observable through the fetch-attempt chain.

## Token sources (fallback order)
1) Config token (`~/.codexbar/config.json` -> `providers[].apiKey` for provider `alibaba`).
2) Environment variables, checked in order:
   - `ALIBABA_CODING_PLAN_API_KEY`
   - `ALIBABA_QWEN_API_KEY`
   - `DASHSCOPE_API_KEY`

## Region + endpoint behavior
- International host: `https://modelstudio.console.alibabacloud.com`
- China mainland host: `https://bailian.console.aliyun.com`
- Quota request path:
  - `POST /data/api.json?action=zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2&product=broadscope-bailian&api=queryCodingPlanInstanceInfoV2`
- Region is selected in Preferences -> Providers -> Alibaba Coding Plan -> Gateway region.
- Auto fallback behavior:
  - If International fails with credential/host-style API errors, CodexBar retries China mainland once.

### CN API-key limitation (known)
- In some China mainland accounts/environments, the current Alibaba `/data/api.json` coding-plan endpoint can still return console-login-required responses (`ConsoleNeedLogin`) even when an API key is configured.
- In that case, API-key mode may not be functionally available for that account/endpoint, and web session mode is required.
- CodexBar now surfaces this as an API error in API mode (instead of a cookie-login-required message) so the limitation is explicit.

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
- If the payload proves the plan is active but does not expose defensible quota counters, CodexBar preserves the visible plan state without manufacturing a normal quantitative quota window.
- If neither real counters nor a defensible active-plan fallback signal exist, parsing fails explicitly instead of degrading to fake `0%` usage.

## Dashboard links
- International console: `https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=globalset#/efm/coding_plan`
- China mainland console: `https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan`

## Key files
- `Sources/CodexBarCore/Providers/Alibaba/AlibabaCodingPlanProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Alibaba/AlibabaCodingPlanUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/Alibaba/AlibabaCodingPlanUsageSnapshot.swift`
- `Sources/CodexBar/Providers/Alibaba/AlibabaCodingPlanProviderImplementation.swift`
