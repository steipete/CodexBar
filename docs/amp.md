---
summary: "Amp provider notes: CLI usage, web fallback, cookie auth, and credits."
read_when:
  - Adding or modifying the Amp provider
  - Debugging Amp cookie import or settings parsing
  - Adjusting Amp menu labels or usage math
---

# Amp Provider

The Amp provider tracks Amp Free usage, monthly subscription pools, and individual and workspace credits. It prefers the
local Amp CLI, then an Amp access token, and finally browser cookies.

## Features

- **Amp Free meter**: Shows how much daily free usage remains.
- **Daily reset**: Percentage-based Amp Free usage resets at 8:00 PM America/New_York time.
- **Monthly subscriptions**: Shows independent Agent and Orb usage for Tier output, calculated from the exact dollar
  and hour balances instead of rounded CLI percentages. Legacy Subscription output retains its “Other usage” and
  “Orb usage” pools. Missing or unrecognized Orb data does not hide the Agent pool.
- **Monthly allowances**: Keeps remaining Agent dollars and Orb hours separate from individual and workspace credits.
  Orb time is displayed as whole a1.small-equivalent hours, rounded down; positive balances below an hour show `< 1h`.
  Usage calculations retain the full reported precision.
- **Time-to-full reset**: Legacy dollar-based Amp Free output estimates when hourly replenishment reaches full.
- **Individual credits**: Shows the remaining paid balance shared by agent and orb usage when Amp reports one.
- **Workspace credits**: Shows each workspace's remaining paid credit balance separately.
- **Enterprise workspaces**: Workspaces whose usage is paid by an enterprise have no balance, so they are listed as
  Enterprise. With the CLI source, the recorded cost and token totals for the last 30 days are shown instead.
- **Cost history**: Daily recorded cost, token counts, and per-model breakdowns feed the shared cost chart and
  Usage & Spend when cost summaries are enabled. Amounts are Amp's recorded cost, not an estimate. Days follow the
  local calendar.
- **CLI-first fetch**: Uses `amp usage` when the Amp CLI is installed and signed in.
- **Access token support**: Uses `AMP_API_KEY` or the access token saved in CodexBar settings.
- **Browser cookie fallback**: Reads the legacy settings-page payload when the CLI and access token are unavailable.

## Setup

1. Open **Settings → Providers**
2. Enable **Amp**
3. Install and sign in to the Amp CLI, add an Amp access token, or leave **Cookie source** on **Auto** for web fallback

### Access token (optional)

Create an access token in Amp settings, then paste it into **Amp → Access token** or set `AMP_API_KEY`.

### Manual cookie import (optional)

1. Open `https://ampcode.com/settings`
2. Copy a `Cookie:` header from your browser’s Network tab
3. Paste it into **Amp → Cookie Source → Manual**

## How it works

- Runs `amp usage` first in automatic mode
- For enterprise-paid workspaces, runs `amp usage --details --start … --end …` over the last 30 days, then once
  per active day, because Amp reports tokens and models only for the whole requested range. Days follow the
  Statistics time zone. Day queries run up to eight at a time; days that ended more than six hours ago are reused
  until CodexBar restarts. All of this is best-effort: a failed range keeps the account, and a failed day marks the
  history as partial and leaves that day's totals unknown instead of zero
- Calls `POST https://ampcode.com/api/internal?userDisplayBalanceInfo` with an Amp access token
- Falls back to the settings page with browser cookies
- Parses the same usage display format returned to the CLI
- Anchors Tier pacing to the reported billing dates; missing or invalid dates disable Tier pacing. These date-only
  fields use UTC day boundaries, so renewal timing and pacing are approximate within a day. Legacy Subscription
  output retains its calendar-month estimate. Daily free usage resets at 8:00 PM New York time.
- Computes time-to-full from the hourly replenishment rate for legacy dollar-based Amp Free output
- Omits unrepresentable replenishment durations while retaining valid free usage. Invalid subscription renewal
  arithmetic does not hide independent credit balances.

### “Amp access token is invalid or expired”

Create a new access token in Amp settings, update `AMP_API_KEY` or CodexBar settings, then refresh.

## Troubleshooting

### “No Amp session cookie found”

Log in to Amp in a supported browser (Safari or Chromium-based), then refresh in CodexBar.

### “Amp session cookie expired”

Sign out and back in at `https://ampcode.com/settings`, then refresh.
