---
summary: "Amp provider notes: CLI usage, web fallback, cookie auth, and credits."
read_when:
  - Adding or modifying the Amp provider
  - Debugging Amp cookie import or settings parsing
  - Adjusting Amp menu labels or usage math
---

# Amp Provider

The Amp provider tracks Amp Free usage plus individual and workspace credits. It prefers the local Amp CLI and falls back to
Amp's web usage endpoint with browser cookies.

## Features

- **Amp Free meter**: Shows how much daily free usage remains.
- **Time-to-full reset**: “Resets in …” indicates when free usage replenishes to full.
- **Individual credits**: Shows the remaining paid credit balance when Amp reports one.
- **Workspace credits**: Shows each workspace's remaining paid credit balance separately.
- **CLI-first fetch**: Uses `amp usage` when the Amp CLI is installed and signed in.
- **Browser cookie fallback**: No separate API key is needed when the CLI is unavailable.

## Setup

1. Open **Settings → Providers**
2. Enable **Amp**
3. Install and sign in to the Amp CLI, or leave **Cookie source** on **Auto** for web fallback

### Manual cookie import (optional)

1. Open `https://ampcode.com/settings`
2. Copy a `Cookie:` header from your browser’s Network tab
3. Paste it into **Amp → Cookie Source → Manual**

## How it works

- Runs `amp usage` first in automatic mode
- Falls back to `POST https://ampcode.com/api/internal?userDisplayBalanceInfo`
- Parses the same usage display format returned to the CLI
- Retains the old settings-page payload parser for older Amp deployments
- Computes time-to-full from the hourly replenishment rate

## Troubleshooting

### “No Amp session cookie found”

Log in to Amp in a supported browser (Safari or Chromium-based), then refresh in CodexBar.

### “Amp session cookie expired”

Sign out and back in at `https://ampcode.com/settings`, then refresh.
