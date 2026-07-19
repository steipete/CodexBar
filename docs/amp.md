---
summary: "Amp provider notes: CLI usage, web fallback, cookie auth, and credits."
read_when:
  - Adding or modifying the Amp provider
  - Debugging Amp cookie import or settings parsing
  - Adjusting Amp menu labels or usage math
---

# Amp Provider

The Amp provider tracks Amp Free usage plus individual and workspace credits. It prefers the local Amp CLI, then an Amp
access token, and finally browser cookies.

## Features

- **Amp Free meter**: Shows how much daily free usage remains.
- **Time-to-full reset**: “Resets in …” indicates when free usage replenishes to full.
- **Individual credits**: Shows the remaining paid credit balance when Amp reports one.
- **Workspace credits**: Shows each workspace's remaining paid credit balance separately.
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
- Calls `POST https://ampcode.com/api/internal?userDisplayBalanceInfo` with an Amp access token
- Falls back to the settings page with browser cookies
- Parses the same usage display format returned to the CLI
- Computes time-to-full from the hourly replenishment rate

### “Amp access token is invalid or expired”

Create a new access token in Amp settings, update `AMP_API_KEY` or CodexBar settings, then refresh.

## Troubleshooting

### “No Amp session cookie found”

Log in to Amp in a supported browser (Safari or Chromium-based), then refresh in CodexBar.

### “Amp session cookie expired”

Sign out and back in at `https://ampcode.com/settings`, then refresh.
