---
summary: "Poe provider: API key setup, point balance, and recent usage history."
read_when:
  - Configuring Poe usage
  - Debugging Poe balance or history requests
---

# Poe Provider

CodexBar reads Poe's official usage API with a manually configured API key. It does not perform OAuth login or import browser cookies.

## Authentication

Create or copy an API key from [Poe API Keys](https://poe.com/api/keys), then add it in CodexBar Settings → Providers → Poe.

You can also set the environment variable:

```bash
export POE_API_KEY="..."
```

Or configure it through the CLI:

```bash
printf '%s' "$POE_API_KEY" | codexbar config set-api-key --provider poe --stdin
```

## Data Source

CodexBar requests:

- `GET https://api.poe.com/usage/current_balance`
- `GET https://api.poe.com/usage/points_history`

The current balance request is required. Recent points history is best-effort, so a history error does not hide a valid balance.

## Display

The provider shows the current point balance in the menu and menu bar. When available, recent history is grouped by day and shown in the usage detail.

## CLI Usage

```bash
codexbar --provider poe
```
