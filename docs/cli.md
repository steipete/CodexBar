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
  - Linux (glibc): `CodexBarCLI-v<tag>-linux-aarch64.tar.gz`, `CodexBarCLI-v<tag>-linux-x86_64.tar.gz`
  - Linux (static musl): `CodexBarCLI-v<tag>-linux-musl-aarch64.tar.gz`, `CodexBarCLI-v<tag>-linux-musl-x86_64.tar.gz`
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
CodexBar reads the resolved config file for provider settings, secrets, and ordering. New installs use
`~/.config/codexbar/config.json`; absolute `XDG_CONFIG_HOME` paths and `CODEXBAR_CONFIG` are supported, and existing
`~/.codexbar/config.json` installs keep using the legacy file when no XDG config exists.
See `docs/configuration.md` for the schema.

## Command
- `codexbar` defaults to the `usage` command.
  - `--format text|json` (default: text).
- `codexbar cost` prints token cost usage for Claude, Codex, and Cursor.
  - Claude and Codex are scanned from local session logs without web/CLI access.
  - Cursor is fetched from the cookie-authenticated cursor.com dashboard API (macOS only; see `docs/cursor.md`) and honors the configured cookie source: a non-empty Manual header is required and forwarded, while Off fails explicitly instead of silently omitting Cursor.
  - `--format text|json` (default: text).
  - `--refresh` ignores cached scans.
- `codexbar cards` prints a one-shot usage snapshot as a responsive terminal card grid.
  - Reuses the same provider, source, account, credits, and status flags as `codexbar usage`.
  - Account lines and plan badges are included in the card grid by default.
  - `--brief` renders a compact table (Provider / Usage / Reset) instead of the card grid.
  - Stdout is always rendered text; `--json-output` only affects stderr logs (no JSON card payload).
  - Failed providers are summarized in a footer (not rendered as error cards).
  - When the opt-in Claude claude-swap integration returns two or more accounts—or one account with
    `claudeSwapShowSingleAccount` enabled—cards renders every account in active-first/slot order instead of the
    ambient or token-account Claude cards. This applies on macOS and Linux, including an explicit
    `--provider claude`; `--source auto` remains eligible.
  - `--account`, `--account-index`, `--all-accounts`, and explicit non-auto source flags preserve their requested
    ambient behavior and do not invoke claude-swap. Zero-account lists always retain ambient Claude output;
    one-account lists do so unless `claudeSwapShowSingleAccount` is enabled.
  - claude-swap sentinel accounts remain successful cards with their problem text and no fabricated usage metrics.
    A list adapter, parser, or timeout failure retains useful ambient Claude output, adds a distinct
    `Claude (claude-swap)` failure footer entry, and makes the command exit non-zero.
  - This precedence is cards-only: `codexbar usage` and `codexbar serve` keep their existing output cardinality.
  - Honors `$COLUMNS` for layout; falls back to 80 columns. Use `--no-color` for plain output.
  - Kitty, Ghostty, WezTerm, and other truecolor terminals auto-enable enhanced gradients/outlines.
  - Force enhanced mode elsewhere with `CODEXBAR_CARDS_ENHANCED=1`.
  - Exit code is non-zero when any provider fetch fails.
- `codexbar serve` starts a foreground HTTP server for usage and cost JSON plus a token-gated dashboard snapshot.
  - `--host <host>` accepts `localhost` or an IPv4 address and defaults to `127.0.0.1`; `localhost` is normalized to `127.0.0.1`. Binding a non-loopback host requires a dashboard token **and** `--allow-plain-http` (see `docs/dashboard-api.md` for the threat model).
  - `--port <port>` defaults to `8080`.
  - `--refresh-interval <seconds>` defaults to `60` and controls the in-memory response cache TTL.
  - `--request-timeout <seconds>` defaults to `30` and bounds each request before returning `504 Gateway Timeout`; use `0` to keep waiting indefinitely.
  - `--dashboard-token <token>` sets the static bearer token for `GET /dashboard/v1/snapshot`. Prefer the `CODEXBAR_DASHBOARD_TOKEN` environment variable (it wins over the flag; a flag value leaks via `ps`). Empty or whitespace-only tokens are startup errors. Without a token the snapshot route fails closed with `401`.
  - On a **non-loopback** host the token gates **all data routes** — `/usage`, `/cost`, and `/dashboard/v1/snapshot` all require `Authorization: Bearer YOUR_TOKEN`, so account data is never exposed to the network unauthenticated. `/health` is always open. On the default loopback bind, `/usage` and `/cost` stay unauthenticated.
  - `--allow-plain-http` is the explicit acknowledgment that the bearer token crosses the network **in cleartext on every request** when serving on a non-loopback host. `serve` refuses to start on a non-loopback host without it.
  - Provider config is reloaded for each usage/cost request; cache entries are keyed by the loaded config so provider toggles and source changes do not require restarting `serve`.
  - Transient refresh failures fall back to the last good response for up to ten refresh intervals (minimum five minutes) so polling clients do not flicker between data and errors; disabled when `--refresh-interval 0`.
  - The default loopback bind rejects non-loopback `Host` headers; a configured non-loopback `--host` additionally accepts its own name. No CORS, TLS, or daemon mode.
  - Endpoints: `GET /health`, `GET /usage`, `GET /usage?provider=<id|both|all>`, `GET /cost`, `GET /cost?provider=<id|both|all>`, `GET /dashboard/v1/snapshot`.
  - `GET /dashboard/v1/snapshot` requires `Authorization: Bearer YOUR_TOKEN`; responses (and all `401`s) carry `Cache-Control: no-store`. The token is never accepted via query string. See `docs/dashboard-api.md` for the payload contract.
  - `GET /health` returns `{"status":"ok"}` plus a `version` field with the running build (e.g. `"0.37.2"`) when resolvable; clients can compare it against `codexbar --version` to detect a `serve` process still running an older binary after an update.
  - Codex usage responses include every visible Codex account, matching the menu bar switcher.
- `codexbar cache clear` clears local CodexBar caches.
  - `--cookies` removes cached browser-cookie headers from the CodexBar Keychain cache.
  - `--cookies --provider <id>` removes browser-cookie cache entries for that provider, including managed Codex account scopes.
  - `--cost` removes local cost-usage scan caches.
  - `--all` clears both cookies and cost caches. `--provider` is cookie-only and cannot be combined with `--cost` or `--all`.
- `codexbar cookie refresh` ignores the provider's current cookie caches while importing a replacement through its web strategy. A failed or interrupted import leaves existing cookies intact.
  - Choose exactly one of `--provider <id>` or `--all`; provider support comes from shared browser-cookie metadata rather than a fixed CLI list.
  - Prompt-capable Chromium imports require `--allow-keychain-prompt`. Without it, the command fails before cache mutation with an interactive-retry hint.
  - A six-hour Keychain-denial cooldown is bypassed only by that explicit acknowledgment flag. Output never includes cookie values.
  - Providers configured for Manual or Off cookie sources are skipped.
- `codexbar guard --provider <id>` gates automation on one provider's remaining quota.
  - `--min-remaining <percent>` sets the inclusive threshold (default: `10`; valid range: `0...100`).
  - `--window session|weekly` selects the primary/session window or secondary/weekly window (default: `session`).
  - `--timeout <seconds>` bounds the complete fetch (range: `0...86400`; default: `60`; `0` disables this guard-level deadline while provider-specific timeouts still apply).
  - `--json` emits the provider, window, remaining quota, threshold, decision, unavailable reason, and exit code; add `--pretty` for formatted JSON.
  - Stable guard exit codes: `0` means safe, `1` means below threshold, `64` (`EX_USAGE`) means invalid arguments, and `69` (`EX_UNAVAILABLE`) means the quota could not be checked or the selected window is unavailable. `--fail-open` changes only unavailable results from `69` to `0`; JSON still reports `decision: "unknown"` and the reason.
  - Guard fetches are read-only and use background interaction policy, matching `codexbar usage`; they never request interactive Keychain access.
- `--provider <id|both|all>` (default: enabled providers in config; falls back to defaults when missing).
  - Provider IDs live in the config file (see `docs/configuration.md`).
  - With three or more providers enabled, the default stays scoped to enabled providers; use `--provider all` to query
    every registered provider.
  - `--account <label>` / `--account-index <n>` / `--all-accounts` (token accounts from config, or all visible Codex accounts for Codex; requires a single provider).
  - `--no-credits` (hide Codex credits in text output).
  - `--pretty` (pretty-print JSON).
  - `--status` (fetch provider status pages and include them in output).
  - `--antigravity-plan-debug` (debug: print Antigravity planInfo fields to stderr).
- `--source <auto|web|cli|oauth|api>` (default: `auto`).
    - `auto`: provider-specific fallback order from `docs/providers.md`.
    - `web`: web-only where that provider exposes an explicit web source; no CLI/API fallback. Browser import is macOS-only, while supported providers can use configured manual cookies on Linux.
    - `cli`: CLI/local-helper source where the provider exposes one (for example Codex RPC/PTy, Claude PTY, Kilo CLI fallback, Kiro CLI, local probes).
    - `oauth`: OAuth-backed source where supported (Codex, Claude, Vertex AI).
    - `api`: API-key/token flow when the provider supports it (OpenAI, Claude Admin API, z.ai, Gemini, Alibaba, Copilot, Kilo, Kimi, MiniMax, Ollama, Warp, OpenRouter, ElevenLabs, Deepgram, Synthetic, DeepSeek, DeepInfra, Moonshot, Doubao, Codebuff, Crof, Venice, AWS Bedrock).
    - Output `source` reflects the strategy actually used (`openai-web`, `web`, `oauth`, `api`, `local`, `cli`, or provider CLI label).
    - Codex web: OpenAI web dashboard (usage limits, credits remaining, code review remaining, usage breakdown).
        - `--web-timeout <seconds>` (default: 60)
        - `--web-debug-dump-html` (writes HTML snapshots to `/tmp` when data is missing)
    - Claude web: claude.ai API (session + weekly usage, plus account metadata when available).
    - Command Code web: commandcode.ai browser session cookies on macOS, or a configured manual cookie on Linux, for monthly credit usage.
    - OpenCode Go auto: local SQLite usage on macOS and Linux, with optional manual-cookie web enrichment.
    - Kilo auto: app.kilo.ai API first, then CLI auth fallback (`~/.local/share/kilo/auth.json`) on missing/unauthorized API credentials.
    - Linux: browser-backed `auto`/`web` modes are not supported; local sources and configured manual-cookie paths remain available where documented.
- Global flags: `-h/--help`, `-V/--version`, `-v/--verbose`, `--no-color`, `--log-level <trace|verbose|debug|info|warning|error|critical>`, `--json-output`, `--json-only`.
  - `--json-output`: JSONL logs on stderr (machine-readable).
  - `--json-only`: suppress non-JSON output; errors become JSON payloads.
- `codexbar config validate` checks the resolved config file for invalid fields.
  - `--format text|json`, `--pretty`, and `--json-only` are supported.
  - Warnings keep exit code 0; errors exit non-zero.
- `codexbar config dump` prints the normalized config JSON.
- `codexbar hooks list` shows the local hook configuration; `--format json` and `--pretty` are supported.
- `codexbar hooks enable|disable` changes the explicit top-level opt-in switch in the local config file.
- `codexbar hooks test <event> --provider <id>` invokes matching enabled rules with a representative event. Hook
  commands run directly without a shell and receive `CODEXBAR_*` variables plus JSON on stdin. `--format json` and
  `--json-only` return structured per-rule results. See
  `docs/configuration.md#external-event-hooks` for the event, payload, timeout, and security contract.

### Token accounts
The CLI reads multi-account tokens from the same resolved config file as the app.
- Select a specific account: `--account <label>` (matches the label/email in the file).
- Select by index (1-based): `--account-index <n>`.
- Fetch all accounts for the provider: `--all-accounts`.
Account selection flags require a single provider (`--provider claude`, etc.).
For Claude, token accounts accept either `sessionKey` cookies or OAuth access tokens (`sk-ant-oat...`).
OAuth usage requires the `user:profile` scope; inference-only tokens will return an error.

### Codex accounts
For Codex, `--all-accounts` and `codexbar serve` enumerate the same visible accounts as the app switcher:
managed Codex accounts from `managed-codex-accounts.json` plus the live system account when present.
Each fetch is scoped to that account's Codex home before the normal Codex web/OAuth/CLI strategy runs, and JSON
payloads include the visible account label in `account`.

### Cost JSON payload
`codexbar cost --format json` emits an array of payloads (one per provider).
- `provider`, `source` (`local` for Claude/Codex log scans, `web` for Cursor dashboard data), `updatedAt`
- `sessionTokens`, `sessionCostUSD`
- `last30DaysTokens`, `last30DaysCostUSD`
- Cursor only: `meteredCostUSD` — what Cursor's plan actually deducts over the window, alongside the API-rate estimate in `last30DaysCostUSD`.
- `daily[]`: `date`, `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheCreationTokens`, `totalTokens`, `totalCost`, `modelsUsed`, `modelBreakdowns[]` (`modelName`, `cost`)
- Codex only: `projects[]`: `name`, `path`, `totalTokens`, `totalCost`, `daily[]`, `modelBreakdowns[]`, `sources[]`
- `totals`: `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheCreationTokens`, `totalTokens`, `totalCost`
- `error`: structured provider error when a fetch fails (for example Cursor requested while its cookie source is Off).

## Example usage
```
codexbar                          # text, respects app toggles
codexbar --provider claude        # force Claude
codexbar --provider all           # query all registered providers
codexbar --format json --pretty   # machine output
codexbar --format json --provider both
codexbar cost                     # cost usage (default 30-day window + today)
codexbar cost --days 90           # choose a 1...365 day cost window
codexbar cost --provider codex --group-by project
codexbar cost --provider claude --format json --pretty
codexbar guard --provider codex --min-remaining 20 --window weekly --json
codexbar cost --provider cursor   # Cursor dashboard cost (API-rate + Cursor-metered)
codexbar serve --port 8080        # localhost HTTP JSON server
codexbar serve --request-timeout 0 # disable serve request deadlines
CODEXBAR_DASHBOARD_TOKEN=YOUR_TOKEN codexbar serve # token-gated dashboard snapshot
CODEXBAR_DASHBOARD_TOKEN=... codexbar serve --host 0.0.0.0 --allow-plain-http # LAN, cleartext accepted
COPILOT_API_TOKEN=... codexbar --provider copilot --format json --pretty
codexbar --status                 # include status page indicator/description
codexbar --provider codex --source oauth --format json --pretty
codexbar --provider codex --source web --format json --pretty
codexbar --provider codex --all-accounts --format json --pretty
codexbar --provider claude --account steipete@gmail.com
codexbar --provider claude --all-accounts --format json --pretty
codexbar --json-only --format json --pretty
codexbar --provider gemini --source api --format json --pretty
KILO_API_KEY=... codexbar --provider kilo --source api --format json --pretty
MOONSHOT_API_KEY=... codexbar --provider moonshot --source api --format json --pretty
codexbar config validate --format json --pretty
codexbar config dump --pretty
printf '%s' "$OPENAI_ADMIN_KEY" | codexbar config set-api-key --provider openai --stdin
codexbar config enable --provider grok
codexbar cache clear --cookies
codexbar cache clear --cookies --provider claude
codexbar cache clear --all --format json --pretty
codexbar cookie refresh --provider opencodego --allow-keychain-prompt
```

### Sample output (text)
```
== Codex 0.6.0 (codex-cli) ==
Session: 72% left [========----]
Pace: 12% in deficit | Expected 16% used | Projected empty in 2h 30m
Resets today at 2:15 PM
Weekly: 41% left [====--------]
Pace: 6% in reserve | Expected 47% used | Lasts until reset
Resets Fri at 9:00 AM
Credits: 112.4 left

== Claude Code 2.0.58 (web) ==
Session: 88% left [==========--]
Pace: On pace | Expected 13% used | Lasts until reset
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
  "pace": {
    "primary": { "stage": "ahead", "deltaPercent": 12, "expectedUsedPercent": 16, "willLastToReset": false, "etaSeconds": 9000, "summary": "12% in deficit | Expected 16% used | Projected empty in 2h 30m" },
    "secondary": { "stage": "slightlyBehind", "deltaPercent": -6, "expectedUsedPercent": 47, "willLastToReset": true, "summary": "6% in reserve | Expected 47% used | Lasts until reset" }
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
- OpenAI API charts require an Admin API key for organization costs/usage. Normal API keys can only use the legacy balance fallback.
- Claude Admin API charts require an Anthropic Admin API key (`sk-ant-admin...` or `ANTHROPIC_ADMIN_KEY`).
- Codex CLI `auto` tries the OpenAI web dashboard, then Codex CLI RPC/PTy; the app’s Codex `auto` path prefers OAuth when credentials are present, then CLI.
- Claude CLI `auto` tries web, then CLI PTY; the app’s Claude `auto` path prefers OAuth, then CLI, then web.
- Kilo text output splits identity into `Plan:` and `Activity:` lines; in `--source auto`, resolved CLI fetches add
  `Note: Using CLI fallback`.
- Kilo auto-mode failures include a fallback-attempt summary line in text mode (API attempt then CLI attempt).
- OpenAI web requires a signed-in `chatgpt.com` session in a supported browser or a manual cookie header. No passwords are stored; CodexBar reuses cookies.
- Safari cookie import may require granting CodexBar Full Disk Access (System Settings → Privacy & Security → Full Disk Access).
- The `openaiDashboard` JSON field is normally sourced from the app’s cached dashboard snapshot; `--source auto|web` refreshes it live via WebKit using a per-account cookie store.
- Future: optional `--from-cache` flag to read the menubar app’s persisted snapshot (if/when that file lands).
