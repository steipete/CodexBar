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

## Organizations

CodexBar can show usage for any Kilo organization the API key belongs to.

- Open Preferences → Providers → Kilo, set the API key, then click **Refresh
  organizations**.
- Toggle the organizations you want to display alongside Personal. Personal is
  always shown.
- When at least one organization is enabled, the menu renders one Kilo card per
  enabled scope.
- The CodexBar fetcher sends the standard `X-KILOCODE-ORGANIZATIONID` header on
  every usage call to scope the response to that organization.
- CLI source mode (`auth.json`): the header is applied to CLI-resolved tokens
  as well. If a CLI token isn't authorized for the chosen organization, that
  card surfaces an unauthorized error while Personal and other enabled scopes
  continue to render normally.
