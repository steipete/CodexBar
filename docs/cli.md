---
summary: "CodexBar CLI for fetching usage from the command line."
read_when:
  - "You want to call CodexBar data from scripts or a terminal."
  - "Adding or modifying Commander-based CLI commands."
  - "Aligning menubar and CLI output/behavior."
---

# CodexBar CLI

A lightweight Commander-based CLI that mirrors the menu bar app’s provider fetchers and config file.
Use it when you need usage numbers in scripts, CI, or dashboards without UI.

## Install
- In the app: **Preferences → Advanced → Install CLI**. This symlinks `CodexBarCLI` to `/usr/local/bin/codexbar` and `/opt/homebrew/bin/codexbar`.
- From the repo, after installing `CodexBar.app` in `/Applications`: `./bin/install-codexbar-cli.sh` (same symlink targets).
- Manual: `ln -sf "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI" /usr/local/bin/codexbar`.

### Release tarball install (macOS/Linux)
- Homebrew formula (Linux today): `brew install steipete/tap/codexbar`.
- Download release tarballs from GitHub Releases:
  - macOS: `CodexBarCLI-v<tag>-macos-arm64.tar.gz`, `CodexBarCLI-v<tag>-macos-x86_64.tar.gz`
  - Linux: `CodexBarCLI-v<tag>-linux-aarch64.tar.gz`, `CodexBarCLI-v<tag>-linux-x86_64.tar.gz`
- Extract and run `./codexbar` (symlink) or `./CodexBarCLI`.

```
tar -xzf CodexBarCLI-v0.17.0-macos-x86_64.tar.gz
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
- `codexbar cost` prints local token cost usage for Claude + Codex without web/CLI access.
  - `--format text|json` (default: text).
  - `--refresh` ignores cached scans.
- `codexbar cache clear` clears local CodexBar caches.
  - `--cookies` removes cached browser-cookie headers from the CodexBar Keychain cache.
  - `--cookies --provider <id>` removes browser-cookie cache entries for that provider, including managed Codex account scopes.
  - `--cost` removes local cost-usage scan caches.
  - `--all` clears both cookies and cost caches. `--provider` is cookie-only and cannot be combined with `--cost` or `--all`.
- `--provider <id|both|all>` (default: enabled providers in config; falls back to defaults when missing).
  - Provider IDs live in the config file (see `docs/configuration.md`).
  - With three or more providers enabled, the default stays scoped to enabled providers; use `--provider all` to query
    every registered provider.
  - `--account <label>` / `--account-index <n>` / `--all-accounts` (token accounts from config; requires a single provider).
  - `--no-credits` (hide Codex credits in text output).
  - `--pretty` (pretty-print JSON).
  - `--status` (fetch provider status pages and include them in output).
  - `--antigravity-plan-debug` (debug: print Antigravity planInfo fields to stderr).
- `--source <auto|web|cli|oauth|api>` (default: `auto`).
    - `auto`: provider-specific fallback order from `docs/providers.md`.
    - `web` (macOS only): web-only where that provider exposes an explicit web source; no CLI/API fallback.
    - `cli`: CLI/local-helper source where the provider exposes one (for example Codex RPC/PTy, Claude PTY, Kilo CLI fallback, Kiro CLI, local probes).
    - `oauth`: OAuth-backed source where supported (Codex, Claude, Vertex AI).
    - `api`: API-key/token flow when the provider supports it (z.ai, Gemini, Alibaba, Copilot, Kilo, Kimi K2, MiniMax, Warp, OpenRouter, Synthetic, DeepSeek, Codebuff).
    - Output `source` reflects the strategy actually used (`openai-web`, `web`, `oauth`, `api`, `local`, `cli`, or provider CLI label).
    - Codex web: OpenAI web dashboard (usage limits, credits remaining, code review remaining, usage breakdown).
        - `--web-timeout <seconds>` (default: 60)
        - `--web-debug-dump-html` (writes HTML snapshots to `/tmp` when data is missing)
    - Claude web: claude.ai API (session + weekly usage, plus account metadata when available).
    - Command Code web: commandcode.ai browser session cookies for monthly credit usage.
    - Kilo auto: app.kilo.ai API first, then CLI auth fallback (`~/.local/share/kilo/auth.json`) on missing/unauthorized API credentials.
    - Linux: web-backed `auto`/`web` modes are not supported; CLI prints an error and exits non-zero for providers that require browser/WebKit access.
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
codexbar --provider all           # query all registered providers
codexbar --format json --pretty   # machine output
codexbar --format json --provider both
codexbar cost                     # local cost usage (last 30 days + today)
codexbar cost --provider claude --format json --pretty
COPILOT_API_TOKEN=... codexbar --provider copilot --format json --pretty
codexbar --status                 # include status page indicator/description
codexbar --provider codex --source oauth --format json --pretty
codexbar --provider codex --source web --format json --pretty
codexbar --provider claude --account steipete@gmail.com
codexbar --provider claude --all-accounts --format json --pretty
codexbar --json-only --format json --pretty
codexbar --provider gemini --source api --format json --pretty
KILO_API_KEY=... codexbar --provider kilo --source api --format json --pretty
codexbar config validate --format json --pretty
codexbar config dump --pretty
codexbar cache clear --cookies
codexbar cache clear --cookies --provider claude
codexbar cache clear --all --format json --pretty
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

== Kilo (cli) ==
Credits: 60% left [=======-----]
40/100 credits
Plan: Kilo Pass Pro
Activity: Auto top-up: visa
Note: Using CLI fallback
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
- CLI binary discovery checks explicit overrides, captured login PATH, inherited PATH, and known install paths before falling back to an interactive shell probe.
- Reset lines follow the in-app reset time display setting when available (default: countdown).
- Text output uses ANSI colors when stdout is a rich TTY; disable with `--no-color` or `NO_COLOR`/`TERM=dumb`.
- Copilot CLI queries require an API token via config `apiKey` or `COPILOT_API_TOKEN`.
- Codex CLI `auto` tries the OpenAI web dashboard, then Codex CLI RPC/PTy; the app’s Codex `auto` path prefers OAuth when credentials are present, then CLI.
- Claude CLI `auto` tries web, then CLI PTY; the app’s Claude `auto` path prefers OAuth, then CLI, then web.
- Kilo text output splits identity into `Plan:` and `Activity:` lines; in `--source auto`, resolved CLI fetches add
  `Note: Using CLI fallback`.
- Kilo auto-mode failures include a fallback-attempt summary line in text mode (API attempt then CLI attempt).
- OpenAI web requires a signed-in `chatgpt.com` session in a supported browser or a manual cookie header. No passwords are stored; CodexBar reuses cookies.
- Safari cookie import may require granting CodexBar Full Disk Access (System Settings → Privacy & Security → Full Disk Access).
- The `openaiDashboard` JSON field is normally sourced from the app’s cached dashboard snapshot; `--source auto|web` refreshes it live via WebKit using a per-account cookie store.
- Future: optional `--from-cache` flag to read the menubar app’s persisted snapshot (if/when that file lands).
