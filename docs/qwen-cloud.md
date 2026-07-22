---
summary: "Qwen Cloud provider notes: cookie auth, 5-hour and weekly token-plan usage, and setup."
read_when:
  - Adding or modifying the Qwen Cloud provider
  - Debugging Qwen Cloud cookie import or token-plan usage fetching
  - Explaining Qwen Cloud setup and limitations to users
---

# Qwen Cloud Provider

The Qwen Cloud provider tracks the **token plan (individual)** subscription credits from the
Qwen Cloud console (`home.qwencloud.com`), including plans that grant hosted Claude model access.

## Features

- **Current quota windows**: Shows 5-hour and weekly usage percentages, reset times, and plan-specific
  credit limits from the same APIs used by the Qwen Cloud dashboard.
- **Cookie-based auth**: Uses browser cookies or a pasted `Cookie:` header.
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

## How it works

- Calls Qwen Cloud's current individual Token Plan APIs through the `sfm_bailian` console gateway:
  `personal/api/v2/usage`, `personal/api/v2/subscription`, and `personal/api/v2/quota-config`.
- The usage response supplies the 5-hour and weekly consumed ratios and reset times. The subscription response
  identifies the active tier, and quota configuration supplies that tier's numeric credit limits.
- Sends form-encoded fields for `product=sfm_bailian`, `action=IntlBroadScopeAspnGateway`,
  `region=ap-southeast-1`, `language=en-US`, a resolved `sec_token`, and the provider-native API payload.
- Uses Qwen Cloud / alibabacloud login cookies, with `sec_token` resolved from the dashboard HTML,
  a `sec_token` cookie, or the `/tool/user/info.json` endpoint
- Supports `QWEN_CLOUD_HOST` and `QWEN_CLOUD_QUOTA_URL` for testing endpoint overrides, and
  `QWEN_CLOUD_COOKIE` for an environment-supplied cookie header
- Endpoint overrides accept full `https://` URLs or bare hosts (for example,
  `QWEN_CLOUD_HOST=home.qwen-cloud.test`), which are normalized to HTTPS; non-HTTPS schemes are rejected

## Limitations

- Qwen Cloud currently supports the web-cookie path only
- API-key auth, token cost summaries, and automatic status polling are not supported
- The default endpoint targets the international Qwen Cloud individual Token Plan APIs

## Troubleshooting

### "No Qwen Cloud session cookies found in browsers"

Log in at `https://home.qwencloud.com/billing/subscription/token-plan-individual` in Chrome, then refresh CodexBar.

### "Qwen Cloud cookie header is invalid"

The pasted header is empty or not a valid Cookie header. Re-copy the request from the Token Plan page after
logging in again.

### "Qwen Cloud login required"

Your Qwen Cloud session is stale. Sign out and back in on the Qwen Cloud console, then refresh CodexBar.
