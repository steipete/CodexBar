---
summary: "Reactive file-based updates, background polling fallback, and error handling."
read_when:
  - Investigating refresh timing or stale data behavior
  - Understanding background task behavior
---

# Refresh loop

## Reactive Updates (Primary)
- Uses FSEvents to watch provider data sources (CLI logs, Gemini config, CodexBar session files).
- When a watched provider updates its local data, the app detects it immediately.
- Triggers a provider-scoped refresh within 2 seconds of the last file change (debounced).
- The menubar icon updates automatically when quota data changes.

## Fallback Polling
- Background refresh every 5 minutes as a safety net.
- Catches any changes that file watching might miss.

## Behavior
- Background refresh runs off-main (`.utility` priority) and updates `UsageStore` (usage + credits + optional web scrape).
- When a provider's usage changes, the app schedules a short follow-up refresh to keep quota bars current during active usage.
- Menubar icon reflects quota changes in real-time through the observation system.
- Stale/error states dim the icon and surface status in-menu.

## Optional future
- Auto-seed a log if none exists via `codex exec --skip-git-repo-check --json "ping"` (currently not executed).

See also: `docs/status.md`, `docs/ui.md`.
