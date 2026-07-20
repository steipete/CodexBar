---
summary: "Qwen Cloud provider notes: cookie auth, token-plan subscription summary endpoint, and setup."
read_when:
  - Adding or modifying the Qwen Cloud provider
  - Debugging Qwen Cloud cookie import or subscription summary fetching
  - Explaining Qwen Cloud setup and limitations to users
---

# Qwen Cloud Provider

The Qwen Cloud provider tracks the **token plan (individual)** subscription credits from the
Qwen Cloud console (`home.qwencloud.com`), including plans that grant hosted Claude model access.

## Features

- **Token-plan usage display**: Shows used, total, and remaining token-plan credits from the Qwen Cloud
  subscription summary.
- **Cookie-based auth**: Uses browser cookies or a pasted `Cookie:` header.
- **Expiry awareness**: Shows the nearest token-plan expiration date as the reset time when the subscription
  summary includes it.

## Setup

1. Open **Settings → Providers**
2. Enable **Qwen Cloud**
3. Leave **Cookie source** on **Auto** (recommended)

### Manual cookie import (optional)

1. Open `https://home.qwencloud.com/billing/subscription/token-plan-individual`
2. Copy a `Cookie:` header from your browser's Network tab
3. Paste it into **Qwen Cloud → Cookie source → Manual**

## How it works

- Fetches `POST https://home.qwencloud.com/data/api.json?action=GetSubscriptionSummary&product=BssOpenAPI-V3`
- Sends form-encoded fields for `product=BssOpenAPI-V3`, `action=GetSubscriptionSummary`,
  `region=ap-southeast-1`, `language=en-US`, a resolved `sec_token`, and
  `params={"productCode":"sfm_tokenplansolo_public_intl"}`
- Uses Qwen Cloud / alibabacloud login cookies, with `sec_token` resolved from the dashboard HTML,
  a `sec_token` cookie, or the `/tool/user/info.json` endpoint
- Parses `CycleTotalValue`, `CycleSurplusValue`, and `EndTime` from the subscription summary's
  `EquityList` (falling back to `TotalValue`/`TotalSurplusValue` when present)
- Supports `QWEN_CLOUD_HOST` and `QWEN_CLOUD_QUOTA_URL` for testing endpoint overrides, and
  `QWEN_CLOUD_COOKIE` for an environment-supplied cookie header

## Limitations

- Qwen Cloud currently supports the web-cookie path only
- API-key auth, token cost summaries, and automatic status polling are not supported
- The default endpoint is the international Qwen Cloud individual token-plan subscription summary

## Troubleshooting

### "No Qwen Cloud session cookies found in browsers"

Log in at `https://home.qwencloud.com/billing/subscription/token-plan-individual` in Chrome, then refresh CodexBar.

### "Qwen Cloud cookie header is invalid"

The pasted header is empty or not a valid Cookie header. Re-copy the request from the Token Plan page after
logging in again.

### "Qwen Cloud login required"

Your Qwen Cloud session is stale. Sign out and back in on the Qwen Cloud console, then refresh CodexBar.
