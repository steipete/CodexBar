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

- **Balance display**: Shows the current MiMo balance as provider identity text.
- **Cookie-based auth**: Uses browser cookies or a pasted `Cookie:` header.
- **Near-real-time updates**: Balance usually reflects within a few minutes.

## Setup

1. Open **Settings → Providers**
2. Enable **Xiaomi MiMo**
3. Leave **Cookie source** on **Auto** (recommended)

### Manual cookie import (optional)

1. Open `https://platform.xiaomimimo.com/#/console/balance`
2. Copy a `Cookie:` header from your browser’s Network tab
3. Paste it into **Xiaomi MiMo → Cookie source → Manual**

## How it works

- Fetches `GET https://platform.xiaomimimo.com/api/v1/balance`
- Requires the `api-platform_serviceToken` and `userId` cookies
- Accepts optional MiMo cookies like `api-platform_ph` and `api-platform_slh` when present
- Supports `MIMO_API_URL` to override the base API URL for testing

## Limitations

- MiMo currently exposes **balance only**
- Token cost, status polling, debug log output, and widgets are not supported yet

## Troubleshooting

### “No Xiaomi MiMo browser session found”

Log in at `https://platform.xiaomimimo.com/#/console/balance` in Chrome, then refresh CodexBar.

### “Xiaomi MiMo requires the api-platform_serviceToken and userId cookies”

The pasted header or imported browser session is missing required cookies. Re-copy the request from the balance page after logging in again.

### “Xiaomi MiMo browser session expired”

Your MiMo login is stale. Sign out and back in on the MiMo site, then refresh CodexBar.
