---
summary: "Claude provider data sources: OAuth API, web API (cookies), CLI PTY, and local cost usage."
read_when:
  - Debugging Claude usage/status parsing
  - Updating Claude OAuth/web endpoints or cookie import
  - Adjusting Claude CLI PTY automation
  - Reviewing local cost usage scanning
---

# Claude provider

Claude supports three usage data paths plus local cost usage. Source selection is automatic unless debug override is set.

## Data sources + selection order

### Default selection (debug menu disabled)
1) OAuth API (if Claude CLI credentials include `user:profile` scope).
2) CLI PTY (`claude`), if OAuth is unavailable or fails.
3) Web API (browser cookies, `sessionKey`), if OAuth + CLI are unavailable or fail.

Usage source picker:
- Preferences → Providers → Claude → Usage source (Auto/OAuth/Web/CLI).

## Keychain prompt policy (Claude OAuth)
- Preferences → Providers → Claude → Keychain prompt policy.
- Options:
  - `Never prompt`: never attempts interactive Claude OAuth Keychain prompts.
  - `Only on user action` (default): interactive prompts are reserved for user-initiated repair flows.
  - `Always allow prompts`: allows interactive prompts in both user and background flows.
- This setting only affects Claude OAuth Keychain prompting behavior; it does not switch your Claude usage source.
- If Preferences → Advanced → Disable Keychain access is enabled, this policy remains visible but inactive until
  Keychain access is re-enabled.

### Debug selection (debug menu enabled)
- The Debug pane can force OAuth / Web / CLI.
- Web extras are internal-only (not exposed in the Providers pane).

## OAuth API (preferred)
- Credentials:
  - Keychain service: `Claude Code-credentials` (primary on macOS).
  - File fallback: `~/.claude/.credentials.json`.
- Requires `user:profile` scope (CLI tokens with only `user:inference` cannot call usage).
- Endpoint:
  - `GET https://api.anthropic.com/api/oauth/usage`
- Headers:
  - `Authorization: Bearer <access_token>`
  - `anthropic-beta: oauth-2025-04-20`
- Mapping:
  - `five_hour` → session window.
  - `seven_day` → weekly window.
  - `seven_day_sonnet` / `seven_day_opus` → model-specific weekly window.
  - `extra_usage` → Extra usage cost (monthly spend/limit).
- Plan inference: `rate_limit_tier` from credentials maps to Max/Pro/Team/Enterprise.

## Web API (cookies)
- Preferences → Providers → Claude → Cookie source (Automatic or Manual).
- Manual mode accepts a `Cookie:` header from a claude.ai request.
- Multi-account manual tokens: add entries to `~/.codexbar/config.json` (`tokenAccounts`) and set Claude cookies to
  Manual. The menu can show all accounts stacked or a switcher bar (Preferences → Advanced → Display).
- Claude token accounts accept either `sessionKey` cookies or OAuth access tokens (`sk-ant-oat...`). OAuth tokens use
  the Anthropic OAuth usage endpoint; to force cookie mode, paste `sessionKey=<value>` or a full `Cookie:` header.
- Cookie source order:
  1) Safari: `~/Library/Cookies/Cookies.binarycookies`
  2) Chrome/Chromium forks: `~/Library/Application Support/Google/Chrome/*/Cookies`
  3) Firefox: `~/Library/Application Support/Firefox/Profiles/*/cookies.sqlite`
- Domain: `claude.ai`.
- Cookie name required:
  - `sessionKey` (value prefix `sk-ant-...`).
- Cached cookies: Keychain cache `com.steipete.codexbar.cache` (account `cookie.claude`, source + timestamp).
  Reused before re-importing from browsers.
- API calls (all include `Cookie: sessionKey=<value>`):
  - `GET https://claude.ai/api/organizations` → org UUID.
  - `GET https://claude.ai/api/organizations/{orgId}/usage` → session/weekly/opus.
  - `GET https://claude.ai/api/organizations/{orgId}/overage_spend_limit` → Extra usage spend/limit.
  - `GET https://claude.ai/api/account` → email + plan hints.
- Outputs:
  - Session + weekly + model-specific percent used.
  - Extra usage spend/limit (if enabled).
  - Account email + inferred plan.

## CLI PTY (fallback)
- Runs `claude` in a PTY session (`ClaudeCLISession`).
- Default behavior: exit after each probe; Debug → "Keep CLI sessions alive" keeps it running between probes.
- Command flow:
  1) Start CLI with `--allowed-tools ""` (no tools).
  2) Auto-respond to first-run prompts (trust files, workspace, telemetry).
  3) Send `/usage`, wait for rendered panel; send Enter retries if needed.
  4) Optionally send `/status` to extract identity fields.
- Parsing (`ClaudeStatusProbe`):
  - Strips ANSI, locates "Current session" + "Current week" headers.
  - Extracts percent left/used and reset text near those headers.
  - Parses `Account:` and `Org:` lines when present.
  - Surfaces CLI errors (e.g. token expired) directly.

## Cost usage (local log scan)
- Source roots:
  - `$CLAUDE_CONFIG_DIR` (comma-separated), each root uses `<root>/projects`.
  - Fallback roots:
    - `~/.config/claude/projects`
    - `~/.claude/projects`
- Files: `**/*.jsonl` under the project roots.
- Parsing:
  - Lines with `type: "assistant"` and `message.usage`.
  - Uses per-model token counts (input, cache read/create, output).
  - Deduplicates streaming chunks by `message.id + requestId` (usage is cumulative per chunk).
- Cache:
  - `~/Library/Caches/CodexBar/cost-usage/claude-v1.json`

## Key files
- OAuth: `Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/*`
- Web API: `Sources/CodexBarCore/Providers/Claude/ClaudeWeb/ClaudeWebAPIFetcher.swift`
- CLI PTY: `Sources/CodexBarCore/Providers/Claude/ClaudeStatusProbe.swift`,
  `Sources/CodexBarCore/Providers/Claude/ClaudeCLISession.swift`
- Cost usage: `Sources/CodexBarCore/CostUsageFetcher.swift`,
  `Sources/CodexBarCore/Vendored/CostUsage/*`
