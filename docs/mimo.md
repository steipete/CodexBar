---
summary: "Xiaomi MiMo provider notes: cookie auth, balance endpoint, and setup."
read_when:
  - Adding or modifying the Xiaomi MiMo provider
  - Debugging MiMo cookie import or balance fetching
  - Explaining MiMo setup and limitations to users
---

# Xiaomi MiMo Provider

The Xiaomi MiMo provider tracks your current balance from the Xiaomi MiMo console.

## Features

- **Balance display**: Shows total balance plus paid and granted components when MiMo returns them.
- **Token plan usage**: Shows current token-plan credits while retaining balance as a second metric.
- **Cookie-based auth**: Uses browser cookies or a pasted `Cookie:` header.
- **Near-real-time updates**: Balance usually reflects within a few minutes.

## Setup

1. Open **Settings → Providers**
2. Enable **Xiaomi MiMo**
3. Leave **Cookie source** on **Auto** (recommended)

CodexBar imports cookies from these browsers in order: **Safari**, **Chrome** / **Chrome Beta** / **Chrome Canary**, **Firefox**, and **Microsoft Edge**. Switch to **Manual** and paste a `Cookie:` header if your active MiMo session lives in Arc, Brave, or another browser profile CodexBar does not auto-detect.

Safari cookie import may require granting CodexBar Full Disk Access in **System Settings → Privacy & Security**.

### Manual cookie import (optional)

1. Open `https://platform.xiaomimimo.com/#/console/balance`
2. Copy a `Cookie:` header from your browser’s Network tab
3. Paste it into **Xiaomi MiMo → Cookie source → Manual**

## How it works

- Fetches balance and token-plan detail/usage endpoints under `https://platform.xiaomimimo.com/api/v1`
- Requires the `api-platform_serviceToken` and `userId` cookies
- Accepts optional MiMo cookies like `api-platform_ph` and `api-platform_slh` when present
- Supports `MIMO_API_URL` to override the base API URL for testing

## Limitations

- Token cost, status polling, and debug log output are not supported yet
- Widgets do not support Xiaomi MiMo yet
- Auto import covers Safari, Chrome variants, Firefox, and Edge only; other browsers use **Manual** mode

## Troubleshooting

### “No Xiaomi MiMo browser session found”

Log in at `https://platform.xiaomimimo.com/#/console/balance` in Safari, Chrome, Firefox, or Edge, then refresh CodexBar. If your session lives in another browser, switch the MiMo provider to **Cookie source → Manual** and paste the `Cookie:` header instead.

### “Xiaomi MiMo requires the api-platform_serviceToken and userId cookies”

The pasted header or imported browser session is missing required cookies. Re-copy the request from the balance page after logging in again.

### “Xiaomi MiMo browser session expired”

Your MiMo login is stale. Sign out and back in on the MiMo site, then refresh CodexBar.
