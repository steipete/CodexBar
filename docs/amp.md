# Amp Provider

The Amp provider tracks your Amp Free usage by scraping the Amp settings page with browser cookies.

## Features

- **Amp Free meter**: Shows how much daily free usage remains.
- **Time-to-full reset**: “Resets in …” indicates when free usage replenishes to full.
- **Browser cookie auth**: No API keys needed.

## Setup

1. Open **Settings → Providers**
2. Enable **Amp**
3. Leave **Cookie source** on **Auto** (recommended)

### Manual cookie import (optional)

1. Open `https://ampcode.com/settings`
2. Copy a `Cookie:` header from your browser’s Network tab
3. Paste it into **Amp → Cookie Source → Manual**

## How it works

- Fetches `https://ampcode.com/settings`
- Parses the embedded `freeTierUsage` payload
- Computes time-to-full from the hourly replenishment rate

## Troubleshooting

### “No Amp session cookie found”

Log in to Amp in a supported browser (Safari or Chromium-based), then refresh in CodexBar.

### “Amp session cookie expired”

Sign out and back in at `https://ampcode.com/settings`, then refresh.
