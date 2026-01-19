---
summary: "CodexBar CLI for fetching usage from the command line."
read_when:
  - "You want to call CodexBar data from scripts or a terminal."
  - "Adding or modifying Commander-based CLI commands."
  - "Aligning menubar and CLI output/behavior."
---

# CodexBar CLI

A lightweight Commander-based CLI that mirrors the menubar app’s data paths (Codex web/RPC → PTY fallback; Claude web by default with CLI fallback and OAuth debug).
Use it when you need usage numbers in scripts, CI, or dashboards without UI.

## Install
- In the app: **Preferences → Advanced → Install CLI**. This symlinks `CodexBarCLI` to `/usr/local/bin/codexbar` and `/opt/homebrew/bin/codexbar`.
- From the repo: `./bin/install-codexbar-cli.sh` (same symlink targets).
- Manual: `ln -sf "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI" /usr/local/bin/codexbar`.

### Linux install
- Homebrew (Linuxbrew, Linux only): `brew install steipete/tap/codexbar`.
- Download `CodexBarCLI-v<tag>-linux-<arch>.tar.gz` from GitHub Releases (x86_64 + aarch64).
- Extract; run `./codexbar` (symlink) or `./CodexBarCLI`.

```
tar -xzf CodexBarCLI-v0.17.0-linux-x86_64.tar.gz
./codexbar --version
./codexbar usage --format json --pretty
```

## Build
- `./Scripts/package_app.sh` (or `./Scripts/compile_and_run.sh`) bundles `CodexBarCLI` into `CodexBar.app/Contents/Helpers/CodexBarCLI`.
- Standalone: `swift build -c release --product CodexBarCLI` (binary at `./.build/release/CodexBarCLI`).
- Dependencies: Swift 6.2+, Commander package (`https://github.com/steipete/Commander`).

## Configuration
CodexBar reads `~/.codexbar/config.json` for provider settings, secrets, and ordering.
See `docs/configuration.md` for the schema.

## Command
- `codexbar` defaults to the `usage` command.
  - `--format text|json` (default: text).
- `codexbar cost` prints local token cost usage (Claude + Codex) without web/CLI access.
  - `--format text|json` (default: text).
  - `--refresh` ignores cached scans.
- `--provider <id|both|all>` (default: enabled providers in config; falls back to defaults when missing).
  - Provider IDs live in the config file (see `docs/configuration.md`).
  - `--account <label>` / `--account-index <n>` / `--all-accounts` (token accounts from config; requires a single provider).
  - `--no-credits` (hide Codex credits in text output).
  - `--pretty` (pretty-print JSON).
  - `--status` (fetch provider status pages and include them in output).
  - `--antigravity-plan-debug` (debug: print Antigravity planInfo fields to stderr).
- `--source <auto|web|cli|oauth|api>` (default: `auto`).
    - `auto` (macOS only): uses browser cookies for Codex + Claude, with CLI fallback only when cookies are missing.
    - `web` (macOS only): web-only; no CLI fallback.
    - `cli`: CLI-only (Codex RPC → PTY fallback; Claude PTY).
    - `oauth`: Claude OAuth only (debug); no fallback. Not supported for Codex.
    - `api`: API key flow when the provider supports it (z.ai, Gemini, Copilot, Kimi K2, MiniMax, Synthetic).
    - Output `source` reflects the strategy actually used (`openai-web`, `web`, `oauth`, `api`, `local`, or provider CLI label).
    - Codex web: OpenAI web dashboard (usage limits, credits remaining, code review remaining, usage breakdown).
        - `--web-timeout <seconds>` (default: 60)
        - `--web-debug-dump-html` (writes HTML snapshots to `/tmp` when data is missing)
    - Claude web: claude.ai API (session + weekly usage, plus account metadata when available).
    - Linux: `web/auto` are not supported; CLI prints an error and exits non-zero.
- Global flags: `-h/--help`, `-V/--version`, `-v/--verbose`, `--no-color`, `--log-level <trace|verbose|debug|info|warning|error|critical>`, `--json-output`, `--json-only`.
  - `--json-output`: JSONL logs on stderr (machine-readable).
  - `--json-only`: suppress non-JSON output; errors become JSON payloads.
- `codexbar config validate` checks `~/.codexbar/config.json` for invalid fields.
  - `--format text|json`, `--pretty`, and `--json-only` are supported.
  - Warnings keep exit code 0; errors exit non-zero.
- `codexbar config dump` prints the normalized config JSON.

### Token accounts
The CLI reads multi-account tokens from `~/.codexbar/config.json` (same file as the app).
- Select a specific account: `--account <label>` (matches the label/email in the file).
- Select by index (1-based): `--account-index <n>`.
- Fetch all accounts for the provider: `--all-accounts`.
Account selection flags require a single provider (`--provider claude`, etc.).
For Claude, token accounts accept either `sessionKey` cookies or OAuth access tokens (`sk-ant-oat...`).
OAuth usage requires the `user:profile` scope; inference-only tokens will return an error.

### Cost JSON payload
`codexbar cost --format json` emits an array of payloads (one per provider).
- `provider`, `source`, `updatedAt`
- `sessionTokens`, `sessionCostUSD`
- `last30DaysTokens`, `last30DaysCostUSD`
- `daily[]`: `date`, `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheCreationTokens`, `totalTokens`, `totalCost`, `modelsUsed`, `modelBreakdowns[]` (`modelName`, `cost`)
- `totals`: `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheCreationTokens`, `totalTokens`, `totalCost`

## Example usage
```
codexbar                          # text, respects app toggles
codexbar --provider claude        # force Claude
codexbar --provider all           # query all providers (honors your logins/toggles)
codexbar --format json --pretty   # machine output
codexbar --format json --provider both
codexbar cost                     # local cost usage (last 30 days + today)
codexbar cost --provider claude --format json --pretty
COPILOT_API_TOKEN=... codexbar --provider copilot --format json --pretty
codexbar --status                 # include status page indicator/description
codexbar --provider codex --source web --format json --pretty
codexbar --provider claude --account steipete@gmail.com
codexbar --provider claude --all-accounts --format json --pretty
codexbar --json-only --format json --pretty
codexbar --provider gemini --source api --format json --pretty
codexbar config validate --format json --pretty
codexbar config dump --pretty
```

### Sample output (text)
```
== Codex 0.6.0 (codex-cli) ==
Session: 72% left [========----]
Resets today at 2:15 PM
Weekly: 41% left [====--------]
Pace: 6% in reserve | Expected 47% used | Lasts until reset
Resets Fri at 9:00 AM
Credits: 112.4 left

== Claude Code 2.0.58 (web) ==
Session: 88% left [==========--]
Resets tomorrow at 1:00 AM
Weekly: 63% left [=======-----]
Pace: On pace | Expected 37% used | Runs out in 4d
Resets Sat at 6:00 AM
Sonnet: 95% left [===========-]
Account: user@example.com
Plan: Pro
```

### Sample output (JSON, pretty)
```json
{
  "provider": "codex",
  "version": "0.6.0",
  "source": "openai-web",
  "status": { "indicator": "none", "description": "Operational", "updatedAt": "2025-12-04T17:55:00Z", "url": "https://status.openai.com/" },
  "usage": {
    "primary": { "usedPercent": 28, "windowMinutes": 300, "resetsAt": "2025-12-04T19:15:00Z" },
    "secondary": { "usedPercent": 59, "windowMinutes": 10080, "resetsAt": "2025-12-05T17:00:00Z" },
    "tertiary": null,
    "updatedAt": "2025-12-04T18:10:22Z",
    "identity": {
      "providerID": "codex",
      "accountEmail": "user@example.com",
      "accountOrganization": null,
      "loginMethod": "plus"
    },
    "accountEmail": "user@example.com",
    "accountOrganization": null,
    "loginMethod": "plus"
  },
  "credits": { "remaining": 112.4, "updatedAt": "2025-12-04T18:10:21Z" },
  "antigravityPlanInfo": null,
  "openaiDashboard": {
    "signedInEmail": "user@example.com",
    "codeReviewRemainingPercent": 100,
    "creditEvents": [
      { "id": "00000000-0000-0000-0000-000000000000", "date": "2025-12-04T00:00:00Z", "service": "CLI", "creditsUsed": 123.45 }
    ],
    "dailyBreakdown": [
      {
        "day": "2025-12-04",
        "services": [{ "service": "CLI", "creditsUsed": 123.45 }],
        "totalCreditsUsed": 123.45
      }
    ],
    "updatedAt": "2025-12-04T18:10:21Z"
  }
}
```

## Exit codes
- 0: success
- 2: provider missing (binary not on PATH)
- 3: parse/format error
- 4: CLI timeout
- 1: unexpected failure

## Notes
- CLI uses the config file for enabled providers, ordering, and secrets.
- Reset lines follow the in-app reset time display setting when available (default: countdown).
- Text output uses ANSI colors when stdout is a rich TTY; disable with `--no-color` or `NO_COLOR`/`TERM=dumb`.
- Copilot CLI queries require an API token via config `apiKey` or `COPILOT_API_TOKEN`.
- Prefer Codex RPC first, then PTY fallback; Claude defaults to web with CLI fallback when cookies are missing.
- OpenAI web requires a signed-in `chatgpt.com` session in Safari, Chrome, or Firefox. No passwords are stored; CodexBar reuses cookies.
- Safari cookie import may require granting CodexBar Full Disk Access (System Settings → Privacy & Security → Full Disk Access).
- The `openaiDashboard` JSON field is normally sourced from the app’s cached dashboard snapshot; `--source auto|web` refreshes it live via WebKit using a per-account cookie store.
- Future: optional `--from-cache` flag to read the menubar app’s persisted snapshot (if/when that file lands).
