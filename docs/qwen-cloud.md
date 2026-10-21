---
summary: "Qwen Cloud provider notes: cookie auth, Team credits, Individual quota windows, and setup."
read_when:
  - Adding or modifying the Qwen Cloud provider
  - Debugging Qwen Cloud cookie import or token-plan usage fetching
  - Explaining Qwen Cloud setup and limitations to users
---

# Qwen Cloud Provider

The Qwen Cloud provider tracks **Team and Individual Token Plan** subscription credits from the
Qwen Cloud console (`home.qwencloud.com`), including plans that grant hosted Claude model access.

## Features

- **Team credit pool**: Shows used and remaining credits, assigned seats, and the next credit-cycle reset. A valid Team
  plan takes precedence when the account also has an Individual plan. Without an active Team plan, Individual usage
  remains available; Team errors are retained as diagnostics when Individual usage succeeds.
  Empty summaries (`Data: {}`, `Data: null`, or an empty group list) mean no Team subscription and do not
  add a warning. Malformed nonempty summaries remain diagnostics.
- **Current quota windows**: Shows reported 5-hour, weekly, and monthly usage percentages, reset times, and plan-specific
  credit limits from the same APIs used by the Qwen Cloud dashboard.
- Monthly-only responses use the primary **Monthly** bar. When rolling windows are also present, monthly usage appears as a separate **Monthly** row; absent quota totals remain unknown.
- **Cookie-based auth**: Uses the shared supported-browser order and access gate, or a pasted `Cookie:` header.
- **Adjustable menu-bar display**: In **Settings → Menu Bar**, add the session/weekly percentage or usage-bar
  items and arrange them like any other provider.

## Setup

1. Open **Settings → Providers**
2. Enable **Qwen Cloud**
3. Leave **Cookie source** on **Auto** (recommended)

### Manual cookie import (optional)

1. Open `https://home.qwencloud.com/billing/subscription/token-plan-individual`
2. Copy a `Cookie:` header from your browser's Network tab
3. Paste it into **Qwen Cloud → Cookie source → Manual**

For Team accounts, use the same procedure from `https://home.qwencloud.com/analytics/token-plan/team`.

## How it works

- The bundled `qwencloud-team` plugin reuses the provider's selected dashboard session. It reads the security token
  from `/tool/user/info.json`, discovers the optional billing selector through `ea-service / LoadHumanInfo`
  (`Data.SellerInfoDto.Nbid`, region `ap-southeast-1`), then calls `BssOpenAPI-V3 / GetSeatSubscriptionSummary` for
  `sfm_tokenplanteams_dp_intl`. The Team gateway uses `cn-hangzhou` and `zh-CN`, including for this International SKU.
  The plugin selects the `credit_value` equity and uses `NextCycleFlushTime`, not subscription expiry, for the reset.
  A successful discovery without a selector retains the console's default session scope. The discovery contract is
  visible in the public console's [shared client](https://q.alcasset.com/code/qwen-cloud/console-home/1.1.44/assets/shared.js)
  and [Team client](https://q.alcasset.com/code/qwen-cloud/console-home/1.1.44/assets/analytics.js).
- Team requests use host-encoded forms and an opaque, origin-scoped cookie session. Existing native cookie selection
  and the Individual fetch path remain in place; this is not a full Individual-provider plugin conversion.
- Expired automatic sessions get one fresh cookie-resolution attempt before Individual fallback, preserving Team
  precedence after login renewal. Manually pasted cookies remain strict and are never replaced by browser cookies.
- Calls Qwen Cloud's current individual Token Plan APIs through the `sfm_bailian` console gateway:
  `personal/api/v2/usage`, `personal/api/v2/subscription`, and `personal/api/v2/quota-config`.
- The usage response supplies the 5-hour, weekly, and monthly consumed ratios and reset times. The subscription response
  identifies the active tier, and quota configuration supplies that tier's numeric credit limits.
- Sends form-encoded fields for `product=sfm_bailian`, `action=IntlBroadScopeAspnGateway`,
  `region=ap-southeast-1`, `language=en-US`, a resolved `sec_token`, and the provider-native API payload.
- Form encoding preserves reserved characters in the security token and JSON parameters, including cookie-derived anonymous IDs.
- Uses Qwen Cloud / alibabacloud login cookies, with `sec_token` resolved from the dashboard HTML,
  a `sec_token` cookie, or the `/tool/user/info.json` endpoint
- Supports `QWEN_CLOUD_HOST` and `QWEN_CLOUD_QUOTA_URL` for testing endpoint overrides, and
  `QWEN_CLOUD_COOKIE` for an environment-supplied cookie header
- Endpoint overrides accept full `https://` URLs or bare hosts (for example,
  `QWEN_CLOUD_HOST=home.qwen-cloud.test`), which are normalized to HTTPS; non-HTTPS schemes are rejected

## Limitations

- Qwen Cloud currently supports the web-cookie path only
- API-key auth, token cost summaries, and automatic status polling are not supported
- Individual requests target the international Qwen Cloud Individual Token Plan APIs
- Team support currently covers one active subscription group. Ambiguous multiple pools and malformed active quotas
  produce a diagnostic instead of an invented aggregate. Existing `QWEN_CLOUD_HOST` / `QWEN_CLOUD_QUOTA_URL` overrides
  retain their Individual behavior and skip the canonical Team endpoint.

## Troubleshooting

### "No Qwen Cloud session cookies found in browsers"

Log in at `https://home.qwencloud.com/billing/subscription/token-plan-individual` in a supported browser, then refresh CodexBar.

### "Qwen Cloud cookie header is invalid"

The pasted header is empty or not a valid Cookie header. Re-copy the request from the Token Plan page after
logging in again.

### "Qwen Cloud login required"

Your Qwen Cloud session is stale. Sign out and back in on the Qwen Cloud console, then refresh CodexBar.
