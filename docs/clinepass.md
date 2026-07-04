---
summary: "ClinePass provider: 5-hour / weekly / monthly usage windows from the Cline account API."
read_when:
  - Debugging ClinePass usage-window parsing
  - Updating ClinePass display
  - Explaining ClinePass setup and environment variables
---

# ClinePass Provider

[ClinePass](https://docs.cline.bot/getting-started/clinepass) is Cline's flat-rate subscription that provides access to open coding models with elevated rate limits through an OpenAI-compatible gateway at `api.cline.bot`. CodexBar surfaces the three rolling usage windows (5-hour, weekly, monthly) as percentage bars — the same data the Cline web dashboard shows — plus the plan name and signed-in account email.

## Authentication

ClinePass uses API key authentication. Create a key at [app.cline.bot](https://app.cline.bot) under **Settings → API Keys**. The same key that authorizes the Chat Completions API also authorizes the account read endpoints CodexBar uses.

### Environment Variable

Set the `CLINE_API_KEY` environment variable:

```bash
export CLINE_API_KEY="sk-..."
```

This matches Cline's own convention, so a key already exported for the Cline CLI/SDK is picked up automatically.

### Settings

You can also configure the API key in CodexBar Settings → Providers → ClinePass.

### CLI config

```bash
printf '%s' "$CLINE_API_KEY" | codexbar config set-api-key --provider clinepass --stdin
```

### Multiple accounts

ClinePass supports multiple API keys (like other API-key providers). Add them under Settings → Providers → ClinePass → API keys; each key is a separate account with its own usage windows, plan, and email. The menu can show all accounts stacked or a switcher bar (Settings → Advanced → Display), and the CLI can target one (`--account <label>`) or all (`--all-accounts`). Keys are stored in the CodexBar config; the selected account's key is injected as `CLINE_API_KEY` for each fetch.

## Data Source

The ClinePass provider fetches data from three read-only account API endpoints (all with `Authorization: Bearer <CLINE_API_KEY>`, wrapped in Cline's `{ success, data, error }` envelope):

1. **User API** (`GET /api/v1/users/me`): Returns the account `id` and `email`.
2. **Plan API** (`GET /api/v1/users/me/plan`): Returns the plan `displayName`.
3. **Usage-limits API** (`GET /api/v1/users/me/plan/usage-limits`): Returns `{ limits: [{ type, percentUsed, resetsAt }] }` where `type` is `five_hour` / `weekly` / `monthly`. This is the same endpoint the Cline web dashboard's "Usage limits" page uses, so the percentages match the dashboard exactly. (Only the literal `me` works here; `/users/{id}/…` returns 404.)

CodexBar maps each window to the shared session / weekly / tertiary rate-window slots (5-hour, weekly, monthly), clamping `percentUsed` to 0–100 and using `resetsAt` for the reset countdown.

## Display

- **5-hour / Weekly / Monthly**: Percentage-used bars with reset countdowns.
- **Plan**: The ClinePass plan display name (e.g. "Cline Pass (Monthly)").
- **Account**: The signed-in account email.

## CLI Usage

```bash
codexbar --provider clinepass
codexbar -p cline  # alias
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `CLINE_API_KEY` | Your Cline API key (required) |
| `CLINE_API_BASE_URL` | Override the base API URL (optional, defaults to `https://api.cline.bot`; loopback HTTP is allowed for local testing) |

## Notes

- The windows are server-computed utilization percentages, refreshed on each poll — the same values the Cline dashboard shows.
- All three API calls are same-origin validated; a redirect to a different origin is rejected.
- The `/api/v1/users/{id}/balance` endpoint exists but reports a pay-as-you-go credit wallet unrelated to the ClinePass subscription, so it is not shown.
