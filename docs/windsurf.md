---
summary: "Windsurf provider notes: local state.vscdb parsing, fields, and troubleshooting."
read_when:
  - Adding or modifying the Windsurf provider
  - Debugging missing Windsurf usage
  - Explaining Windsurf usage data sources
---

# Windsurf provider

Windsurf usage tracking is **local-only**. CodexBar reads Windsurf's cached plan usage from Windsurf's VS Code-style
global storage SQLite database.

## Data source

- Default path (macOS):
  - `~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb`
- Table: `ItemTable`
- Key: `windsurf.settings.cachedPlanInfo`

The value is JSON that includes:
- `planName`
- `startTimestamp` / `endTimestamp` (epoch seconds or milliseconds)
- `usage` totals and used counts for:
  - messages
  - flexCredits

CodexBar maps these into:
- Primary: Messages
- Secondary: Flex Credits
- Reset time: `endTimestamp`

## Overrides

For debugging/tests you can override the DB path:
- `CODEXBAR_WINDSURF_STATE_DB=/absolute/path/to/state.vscdb`
- `WINDSURF_STATE_DB=/absolute/path/to/state.vscdb` (fallback)

## Troubleshooting

If CodexBar shows "Windsurf data not found" or "cached plan usage is missing":
1. Launch Windsurf.
2. Sign in (if needed).
3. Open the Windsurf settings/plan page once so the plan cache is populated.
4. Refresh CodexBar.

## Privacy

CodexBar reads a single SQLite value from a local DB. It does not send this data anywhere and does not write back to
Windsurf's files.
