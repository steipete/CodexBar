---
summary: "Warp provider notes: API token setup and request limit parsing."
read_when:
  - Adding or modifying the Warp provider
  - Debugging Warp API tokens or request limits
  - Adjusting Warp usage labels or reset behavior
---

# Warp Provider

The Warp provider reads credit limits from Warp's GraphQL API using an API token.

## Features

- **Monthly credits usage**: Shows credits used vs. plan limit.
- **Reset timing**: Displays the next refresh time when available.
- **Token-based auth**: Uses API key stored in Settings or env vars.

## Setup

1. Open **Settings → Providers**
2. Enable **Warp**
3. In Warp, open your profile menu → **Settings → Platform → API Keys**, then create a key.
4. Enter the created `wk-...` key in CodexBar.

Reference guide: `https://docs.warp.dev/reference/cli/api-keys`

### Environment variables (optional)

- `WARP_API_KEY`
- `WARP_TOKEN`

## How it works

- Endpoint: `https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo`
- Query: `GetRequestLimitInfo`
- Fields used: `isUnlimited`, `nextRefreshTime`, `requestLimit`, `requestsUsedSinceLastRefresh` (API uses request-named fields for credits)

If `isUnlimited` is true, the UI shows “Unlimited” and a full remaining bar.

## Troubleshooting

### “Missing Warp API key”

Add a key in **Settings → Providers → Warp**, or set `WARP_API_KEY`.

### “Warp API error”

Confirm the token is valid and that your network can reach `app.warp.dev`.
