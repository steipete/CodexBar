---
summary: "Alibaba Token Plan provider notes: Team and Personal/Solo variants, Bailian CLI/browser auth, and setup."
read_when:
  - Adding or modifying the Alibaba Token Plan provider
  - Debugging Alibaba Token Plan cookie import or subscription summary fetching
  - Explaining Alibaba Token Plan setup and limitations to users
---

# Alibaba Token Plan Provider

The Alibaba Token Plan provider tracks Team credits and Personal/Solo rolling-window usage from the Alibaba Cloud console.

## Features

- **Token-plan usage display**: Shows used, total, and remaining token-plan credits when Bailian returns quota totals.
- **Personal/Solo windows**: Shows reported 5-hour, 7-day, and monthly usage, reset times, and tier-specific quota totals. A monthly-only plan uses the primary usage bar; alongside rolling windows, monthly usage appears as a separate Monthly row.
- **Bailian CLI auth**: Reuses a configured `bl` executable without importing browser cookies. Team requires
  read-only AccessKey credentials; Personal/Solo uses a console login.
- **Cookie-based auth**: Uses the shared supported-browser order and access gate, or a pasted `Cookie:` header.
- **Expiry awareness**: Shows the nearest token-plan expiration date as the reset time when the subscription summary includes it.

## Setup

1. Open **Settings -> Providers**
2. Enable **Alibaba Token Plan**
3. Choose the matching **Gateway region** Team or Personal/Solo variant
4. Leave **Usage source** on **Auto** to try the configured Bailian CLI first, then browser cookies
5. Leave **Cookie source** on **Auto** unless using a manually pasted browser cookie

### Mainland Qwen / Qianwen accounts

If you use `platform.qianwenai.com`, search Settings for **Qwen**, **qianwen**, or **qianwenai** to find
**Alibaba Token Plan**. The CLI aliases `qwen-cn`, `qianwen`, and `qianwenai` select this provider; they do not
change its configured gateway region or subscription variant.

For a **Team** subscription that is also visible in the same account's Bailian Token Plan console:

1. Sign in to the [Bailian Token Plan console](https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan)
   and confirm it shows the same Team subscription.
2. Select **China mainland — Team (bailian.console.aliyun.com)** as the gateway region (`cn` in configuration).
3. Choose **Usage source → Browser cookies**. Either allow access to the Bailian browser session, or choose
   **Cookie source → Manual** and follow the manual import steps below, then refresh.

The **Bailian CLI** source requires read-only AccessKey credentials (AK/SK) for Team subscriptions, configured
with `bl auth login --open-api`. Grant `modelstudio:GetSubscriptionSeatDetails`; the
`AliyunTokenPlanReadOnlyAccess` policy includes this permission. See the
[Team seat API documentation](https://help.aliyun.com/zh/model-studio/get-subscription-seat-details).
A console login authenticates the Personal/Solo path; it does not authenticate the Team API.

Choose the Team variant from the subscription shown in Bailian, even if you are its only user. Personal/Solo uses
a different quota API. This route requires a subscription visible in Bailian and does not import `qianwenai.com`
cookies or query that platform directly. A successful fetch still needs to be verified for your account.
The separate [Qwen Cloud provider](qwen-cloud.md) targets `home.qwencloud.com` international subscriptions.

### Manual cookie import (optional)

1. Choose **Usage source → Browser cookies**, then open the Token Plan page using **Open Token Plan** in settings
2. Copy a `Cookie:` header from the quota request in your browser's Network tab. For Personal/Solo, use the
   `.../tokenplan/personal/api/v2/usage` request so the header is scoped to the quota host.
3. Paste it into **Alibaba Token Plan -> Cookie source -> Manual**
4. Refresh and verify that the subscription and quota match the console

Manual cookies do not read Chrome's cookie database or request its **Chrome Safe Storage** Keychain password.
They still expire with the browser session; if the provider reports that login is required, sign in again and
replace the pasted header with one from a fresh quota request.

## How it works

- Automatic mode tries the configured Bailian CLI first.
  A missing CLI, expired CLI login, or unsupported response falls back to the existing browser-cookie path.
- Team selections run `bl token-plan list-seats --page-no <page> --page-size 10 --output json` and paginate
  through all seats. CodexBar sets `DASHSCOPE_BASE_URL` and `BAILIAN_BASE_URL` for the selected mainland or
  international gateway, covering released and newer CLI versions.
  Current active seat credit cycles are aggregated; a reset time is shown only when their cycle end times agree.
- Personal/Solo uses `bl console call --api zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage --data '{}'`
  with `--console-region <region> --console-site <site> --output json`. This reads monthly windows that older
  `bl usage token-plan` versions omit.
- Explicit **Bailian CLI** and **Browser cookies** modes stay strict and do not switch sources.
- The Bailian subprocess receives only PATH, home/config discovery, locale, timezone, and proxy variables,
  plus fixed regional `DASHSCOPE_BASE_URL` and `BAILIAN_BASE_URL` values for Team requests; ambient API keys,
  browser cookies, cloud credentials, and SSH agent state are not inherited.
- The Team browser-cookie path fetches `GetSubscriptionSummary` from the selected international or mainland
  console and parses the credit pool without probing Personal endpoints.
- Personal/Solo variants fetch `usage`, `subscription`, and `quota-config` from the rolling-window API. International
  uses `bailian-singapore-cs.alibabacloud.com`; mainland uses `bailian-cs.console.aliyun.com`.
- Refreshes reuse one HTTP connection pool, keeping dashboard and quota cookie routing and redirect diagnostics separate for each fetch.
- Browser cookies are rebuilt independently for the dashboard and quota hosts. Personal/Solo requests use the
  quota-host cookie header. The dashboard `sec_token` is resolved best-effort and appended when available
  (some accounts get `BailianGateway.Workspace.NotAuthorised` without it); requests still proceed without it.
- Gateway forms preserve reserved characters in security tokens and JSON parameters. Missing or empty optional security tokens remain omitted.
- Config region values are `intl` and `cn` for Team, or `intl-personal` and `cn-personal` for Personal/Solo.
- Supports `ALIBABA_TOKEN_PLAN_HOST` and `ALIBABA_TOKEN_PLAN_QUOTA_URL` for testing endpoint overrides

## Limitations

- Bailian CLI mode requires `bl` on PATH with read-only AK/SK credentials for Team or a console login for
  Personal/Solo; browser cookies remain available as a fallback in Auto mode
- Model API-key auth, token cost summaries, and automatic status polling are not supported
- Live provider auth is not exercised by the test suite; endpoint changes rely on reporter confirmation after release

## Troubleshooting

### "No Alibaba Token Plan session cookies found in browsers"

Log in at `https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan` in a supported browser, then refresh CodexBar.

### "Alibaba Token Plan cookie header is invalid"

The pasted header is empty or not a valid Cookie header. Re-copy the request from the Token Plan page after logging in again.

### "Alibaba Token Plan login required"

Your Bailian session is stale. Sign out and back in on the Bailian console, then refresh CodexBar.

### Empty subscription summary

If Bailian returns `TotalCount: 0`, CodexBar keeps the provider visible but does not show a quota window because the account has no active token-plan subscription summary to graph.
