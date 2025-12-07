---
summary: "CodexBar CLI for fetching usage from the command line."
read_when:
  - "You want to call CodexBar data from scripts or a terminal."
  - "Adding or modifying Commander-based CLI commands."
  - "Aligning menubar and CLI output/behavior."
---

# CodexBar CLI

A lightweight Commander-based CLI that mirrors the menubar app’s data paths (Codex RPC → PTY fallback; Claude PTY).
Use it when you need usage numbers in scripts, CI, or dashboards without UI.

## Install
- In the app: **Preferences → Advanced → Install CLI**. This symlinks `CodexBarCLI` to `/usr/local/bin/codexbar` and `/opt/homebrew/bin/codexbar`.
- From the repo: `./bin/install-codexbar-cli.sh` (same symlink targets).
- Manual: `ln -sf "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI" /usr/local/bin/codexbar`.

## Build
- `./Scripts/package_app.sh` (or `./Scripts/compile_and_run.sh`) bundles `CodexBarCLI` into `CodexBar.app/Contents/Helpers/CodexBarCLI`.
- Standalone: `swift build -c release --product CodexBarCLI` (binary at `./.build/release/CodexBarCLI`).
- Dependencies: Swift 6.2+, Commander package (`https://github.com/steipete/Commander`).

## Command
- `codexbar` defaults to the `usage` command.
  - `--format text|json` (default: text).
  - `--provider codex|claude|both` (default: your in-app toggles; falls back to Codex).
  - `--no-credits` (hide Codex credits in text output).
  - `--pretty` (pretty-print JSON).
  - `--status` (fetch provider status pages and include them in output).
- Global flags: `-h/--help`, `-V/--version`, `-v/--verbose`, `--log-level <trace|verbose|debug|info|warning|error|critical>`, `--json-output`.

## Example usage
```
codexbar                          # text, respects app toggles
codexbar --provider claude        # force Claude
codexbar --format json --pretty   # machine output
codexbar --format json --provider both
codexbar --status                 # include status page indicator/description
```

### Sample output (text)
```
Codex 0.6.0 (codex-cli)
Session: 72% left
Resets today at 2:15 PM
Weekly: 41% left
Resets Fri at 9:00 AM
Credits: 112.4 left

Claude Code 2.0.58 (claude)
Session: 88% left
Resets tomorrow at 1:00 AM
Weekly: 63% left
Resets Sat at 6:00 AM
Sonnet: 95% left
Account: user@example.com
Plan: Pro
```

### Sample output (JSON, pretty)
```json
{
  "provider": "codex",
  "version": "0.6.0",
  "source": "codex-cli",
  "status": { "indicator": "none", "description": "Operational", "updatedAt": "2025-12-04T17:55:00Z", "url": "https://status.openai.com/" },
  "primary": { "usedPercent": 28, "windowMinutes": 300, "resetsAt": "2025-12-04T19:15:00Z" },
  "secondary": { "usedPercent": 59, "windowMinutes": 10080, "resetsAt": "2025-12-05T17:00:00Z" },
  "tertiary": null,
  "updatedAt": "2025-12-04T18:10:22Z",
  "accountEmail": "user@example.com",
  "accountOrganization": null,
  "loginMethod": "plus",
  "credits": { "remaining": 112.4, "updatedAt": "2025-12-04T18:10:21Z" }
}
```

## Exit codes (proposed)
- 0: success
- 2: provider missing (binary not on PATH)
- 3: parse/format error
- 4: CLI timeout
- 1: unexpected failure

## Notes
- CLI reuses menubar toggles when present (prefers `com.steipete.codexbar{,.debug}` defaults), otherwise defaults to Codex only.
- Prefer Codex RPC first, then PTY fallback; Claude stays PTY-only.
- Future: optional `--from-cache` flag to read the menubar app’s persisted snapshot (if/when that file lands).
