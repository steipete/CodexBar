---
summary: "Rovo Dev provider: Atlassian API token setup and monthly credit usage."
read_when:
  - Adding or modifying the Rovo Dev provider
  - Debugging Rovo Dev credentials or credit usage parsing
  - Troubleshooting acli / ROVODEV_API_TOKEN auth issues
---

# Rovo Dev Provider

The Rovo Dev provider tracks monthly credit usage for [Atlassian Rovo Dev](https://www.atlassian.com/software/rovo-dev) — Atlassian's AI coding agent (CLI, code review, and PR analysis).

## Features

- Monthly credits used / total (e.g. `847 / 2000 credits`).
- Account status: Active, Rate Limited, Blocked.
- Auth: Atlassian email + API token via HTTP Basic auth.
- Source mode: `api` only (no CLI-parse fallback needed).

## Plans and credit allowances

| Plan | Credits |
|------|---------|
| Rovo Dev Free | 350 credits / user / month / site |
| Rovo Dev Standard | 2,000 credits / user / month |

## Setup

### 1. Create an Atlassian API token

Go to [id.atlassian.com → Security → API tokens](https://id.atlassian.com/manage-profile/security/api-tokens) and create a new token. A standard (non-scoped) API token works; you do not need a scoped Rovo Dev token.

### 2. Configure via Settings

1. Open **Settings → Providers → Rovo Dev**
2. Enable the provider
3. Enter your **Atlassian email** (e.g. `you@example.com`)
4. Paste the **API token** (starts with `ATATT3x...`)

### 3. Configure via CLI

```bash
# Set the API token
printf '%s' "$MY_API_TOKEN" | codexbar config set-api-key --provider rovodev --stdin

# Set the email (stored as workspaceID in config)
codexbar config set --provider rovodev workspaceID "you@example.com"
```

### 4. Configure via Environment Variables

```bash
export ROVODEV_API_TOKEN="ATATT3x..."
export ROVODEV_EMAIL="you@example.com"
```

For self-hosted proxies or testing, override the API base URL:

```bash
export ROVODEV_API_URL="https://my-proxy.example.com"
```

## How It Works

- **Endpoint:** `GET https://api.atlassian.com/rovodev/v3/credits/check`
- **Auth:** HTTP Basic — `base64(email:apiToken)`
- **Response fields used:**
  - `status` — `OK`, `RATE_LIMITED`, `USER_BLOCKED`, `UNKNOWN`
  - `balance.monthlyUsed` — credits consumed this month
  - `balance.monthlyTotal` — monthly credit allowance
  - `balance.monthlyRemaining` — credits remaining
  - `balance.dailyUsed` / `balance.dailyTotal` — daily fallback if monthly fields are absent
  - `message` — optional human-readable status message

## Credential Resolution Order

The fetch strategy tries credentials in this order:

1. `ROVODEV_API_TOKEN` + `ROVODEV_EMAIL` environment variables
2. Settings-stored values (email saved as `workspaceID`, token as `apiKey` in `~/.codexbar/config.json`)
3. Token accounts (label = email, token = API token)

## Troubleshooting

### "Missing Rovo Dev credentials"

Make sure both `ROVODEV_API_TOKEN` **and** `ROVODEV_EMAIL` are set, or that both the email and API token fields are filled in **Settings → Providers → Rovo Dev**.

### HTTP 401 Unauthorized

The API token is invalid or expired. Generate a new one at `id.atlassian.com → API tokens`.

### HTTP 403 Forbidden

Your account does not have access to the Rovo Dev API on `api.atlassian.com/rovodev/v3/credits/check`. Confirm:
- Rovo Dev is enabled for your Atlassian site.
- Your account has a Rovo Dev Free or Standard subscription.
- You are authenticating with the correct email/token pair.

### Credits show zero or unknown

The `credits/check` endpoint may not return monthly balance fields for all plan types. The provider falls back to daily balance fields if monthly ones are absent.

## Related

- [Rovo Dev pricing](https://www.atlassian.com/software/rovo-dev/pricing)
- [View your Rovo Dev credit usage](https://support.atlassian.com/rovo/docs/view-your-rovo-dev-credit-usage/)
- [Atlassian API tokens](https://id.atlassian.com/manage-profile/security/api-tokens)
- [Rovo Dev status](https://status.atlassian.com)
