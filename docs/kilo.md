---
summary: "Kilo provider data sources: app.kilo.ai API token and CLI auth-file fallback."
read_when:
  - Adding or modifying the Kilo provider
  - Adjusting Kilo source-mode fallback behavior
  - Troubleshooting Kilo credentials/auth sessions
---

# Kilo provider

Kilo supports API and CLI-backed auth. Source mode can be `auto`, `api`, or `cli`.

## Data sources + fallback order
1. API (`api`)
   - Token from `~/.codexbar/config.json` (`providers[].apiKey` for `kilo`) or `KILO_API_KEY`.
   - Calls `https://app.kilo.ai/api/trpc`.
2. CLI session (`cli`)
   - Reads `~/.local/share/kilo/auth.json` and uses `kilo.access`.
   - Requires a valid CLI login (`kilo login`).
3. Auto (`auto`)
   - Tries API first.
   - Falls back to CLI only when API credentials are missing or unauthorized (401/403).

## Settings
- Preferences -> Providers -> Kilo:
  - Usage source: `Auto`, `API`, `CLI`
  - API key: optional override for `KILO_API_KEY`
- In auto mode, resolved CLI fetches can show a fallback note in menu and CLI output.

## CLI output notes
- Kilo text output splits identity into `Plan:` and `Activity:` lines.
- Auto-mode failures include ordered fallback-attempt details in text mode.

## Troubleshooting
- Missing API token: set `KILO_API_KEY` or provider `apiKey`.
- Missing CLI session file: run `kilo login` to create `~/.local/share/kilo/auth.json`.
- Unauthorized API token (401/403): refresh `KILO_API_KEY` or rerun `kilo login`.
