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

This integration is experimental. Atlassian does not publish the credits endpoint or its Basic-auth contract as
a public API, so compatibility can change without notice.

## Plans and credit allowances

| Plan | Credits |
|------|---------|
| Rovo Dev Free | 350 credits / user / month / site |
| Rovo Dev Standard | 2,000 credits / user / month |

## Setup

### 1. Create an Atlassian API token

Go to [id.atlassian.com → Security → API tokens](https://id.atlassian.com/manage-profile/security/api-tokens)
and create a token. The provider currently expects an Atlassian API token plus the matching account email.

### 2. Configure via Settings

1. Open **Settings → Providers → Rovo Dev**
2. Enable the provider
3. Enter your **Atlassian email** (e.g. `you@example.com`)
4. Paste the **API token** (starts with `ATATT3x...`)

### 3. Configure via Environment Variables

```bash
export ROVODEV_API_TOKEN="ATATT3x..."
export ROVODEV_EMAIL="you@example.com"
```

The CLI can update the stored API token, but the required email must still be configured in Settings or through
`ROVODEV_EMAIL`:

```bash
printf '%s' "$MY_API_TOKEN" | codexbar config set-api-key --provider rovodev --stdin
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

Settings-stored values override the matching environment variable when present. Unset Settings fields fall back to
`ROVODEV_API_TOKEN` or `ROVODEV_EMAIL`.

> **Note:** Token accounts are not supported for Rovo Dev because this provider requires two separate credentials (email + API token). Use environment variables or Settings instead.

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
