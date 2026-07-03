---
summary: "Claude provider data sources: OAuth API, web API (cookies), CLI PTY, and local cost usage."
read_when:
  - Debugging Claude usage/status parsing
  - Updating Claude OAuth/web endpoints or cookie import
  - Adjusting Claude CLI PTY automation
  - Reviewing local cost usage scanning
---

# Claude provider

Claude supports three usage data paths plus local cost usage. The main provider pipeline uses runtime-specific
automatic selection, but the codebase still has multiple active Claude `.auto` decision sites while the refactor is
pending. For the exact current-state parity contract, see
[docs/refactor/claude-current-baseline.md](refactor/claude-current-baseline.md).

When an Anthropic Admin API key is configured, Claude can also show organization-level spend/messages/tokens in the
same inline dashboard pattern used by the OpenAI API provider.

## Data sources + selection order

### Default selection (debug menu disabled)
- If an Admin API key is configured, the Admin API strategy is used for Claude API spend/usage.
- App runtime main pipeline: OAuth API → CLI PTY → Web API.
- CLI runtime main pipeline: Web API → CLI PTY.
- Explicit picker modes (OAuth/Web/CLI) bypass automatic fallback.
- A lower-level direct Claude fetcher still contains a separate `.auto` order. That inconsistency is tracked in
  [docs/refactor/claude-current-baseline.md](refactor/claude-current-baseline.md).

Usage source picker:
- Preferences → Providers → Claude → Usage source (Auto/OAuth/Web/CLI).

Admin API key setup:
- Preferences → Providers → Claude → Admin API key, stored in `~/.codexbar/config.json`.
- CLI/env: `printf '%s' "$ANTHROPIC_ADMIN_KEY" | codexbar config set-api-key --provider claude --stdin`.
- Token accounts can also hold `sk-ant-admin...` keys; they route to the Admin API instead of cookie/OAuth usage.
- Environment fallback: `ANTHROPIC_ADMIN_KEY`.

## Admin API
- Key prefix: `sk-ant-admin...`.
- Endpoints:
  - `/v1/organizations/cost_report`
  - `/v1/organizations/usage_report/messages`
- Output:
  - Today/7d/30d spend and message/token summaries.
  - Inline 30-day dashboard chart when daily buckets are present.
  - Identity login method: `Admin API`.

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
  - CodexBar OAuth cache when available.
  - File fallback: `~/.claude/.credentials.json`.
  - Claude CLI Keychain bootstrap/repair fallback: `Claude Code-credentials`.
- On Claude Code 2.1.x, `Claude Code-credentials` may contain only MCP server OAuth state (`mcpOAuth`) with no `claudeAiOauth`. CodexBar treats that as an OAuth configuration error, does not run background delegated `claude /status` refresh, and surfaces re-auth guidance. Use Web or CLI usage source, or restore a valid Claude OAuth keychain entry. See #1844.
- Requires `user:profile` scope (CLI tokens with only `user:inference` cannot call usage).
- Endpoint:
  - `GET https://api.anthropic.com/api/oauth/usage`
- Headers:
  - `Authorization: Bearer <access_token>`
  - `anthropic-beta: oauth-2025-04-20`
- Mapping:
  - `five_hour` → session window.
  - `seven_day` → weekly window; also becomes the primary fallback when `five_hour` is absent or has no utilization.
  - `seven_day_sonnet` / `seven_day_opus` → model-specific weekly window.
  - `seven_day_routines` / `seven_day_cowork` → Daily Routines extra window.
  - Claude Design/Omelette keys are ignored because Claude Design shares the main Claude usage limit.
  - `extra_usage` → Extra usage cost (monthly spend/limit).
- Successful OAuth login enables Claude and selects OAuth as the usage source.
- Plan inference: `subscriptionType` is preferred when present; `rate_limit_tier` falls back to
  Max/Pro/Team/Enterprise.

## Web API (cookies)
- Preferences → Providers → Claude → Cookie source (Automatic or Manual).
- Manual mode accepts a `Cookie:` header from a claude.ai request.
- Multi-account manual tokens: add entries to `~/.codexbar/config.json` (`tokenAccounts`) and set Claude cookies to
  Manual. The menu can show all accounts stacked or a switcher bar (Preferences → Advanced → Display).
- Claude token accounts accept either `sessionKey` cookies or OAuth access tokens (`sk-ant-oat...`). OAuth-token
  accounts route to the OAuth path and disable cookie mode; session-key or cookie-header accounts stay in manual
  cookie mode. The exact edge-routing rules are documented in
  [docs/refactor/claude-current-baseline.md](refactor/claude-current-baseline.md).
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
  - Daily Routines extra window when returned by the usage API.
  - Extra usage spend/limit (if enabled).
  - Account email + inferred plan.

## CLI PTY (fallback)
- Runs `claude` in a PTY session (`ClaudeCLISession`).
- Default behavior: exit after each probe; Debug → "Keep CLI sessions alive" keeps it running between probes.
- Probe working directory: `~/Library/Application Support/CodexBar/ClaudeProbe` with local Claude settings that disable
  deep-link URL handler registration during headless probes.
- After transient probes exit, CodexBar removes Claude Code `.jsonl` session artifacts for that dedicated
  `ClaudeProbe` project directory so background `/usage` polling does not clutter the user's Claude project history.
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
  - Some Education and organization-managed subscriptions return only a subscription notice, with no numeric
    session or weekly quota fields. CodexBar reports those limits as unavailable, keeps local cost/token history
    visible, and never derives quota percentages from spend or token totals.

## Cost usage (local log scan)
- Source roots:
  - Native Claude logs:
    - `$CLAUDE_CONFIG_DIR` (comma-separated), each root uses `<root>/projects`.
    - Fallback roots:
      - `~/.config/claude/projects`
      - `~/.claude/projects`
  - Supported pi sessions:
    - `~/.pi/agent/sessions/**/*.jsonl`
- Files: `**/*.jsonl` under the native project roots plus supported pi session files.
- Parsing:
  - Native Claude logs parse lines with `type: "assistant"` and `message.usage`.
  - Uses per-model token counts (input, cache read/create, output).
  - Deduplicates streaming chunks by `message.id + requestId` (usage is cumulative per chunk).
  - pi sessions attribute `anthropic` assistant usage to Claude and bucket it by assistant-turn timestamp, so a single pi
    session can contribute to multiple models/days.
- Cache:
  - Native + merged provider cache: `~/Library/Caches/CodexBar/cost-usage/claude-v2.json`
  - pi session cache: `~/Library/Caches/CodexBar/cost-usage/pi-sessions-v1.json`

## Key files
- OAuth: `Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/*`
- Web API: `Sources/CodexBarCore/Providers/Claude/ClaudeWeb/ClaudeWebAPIFetcher.swift`
- CLI PTY: `Sources/CodexBarCore/Providers/Claude/ClaudeStatusProbe.swift`,
  `Sources/CodexBarCore/Providers/Claude/ClaudeCLISession.swift`
- Cost usage: `Sources/CodexBarCore/CostUsageFetcher.swift`,
  `Sources/CodexBarCore/PiSessionCostScanner.swift`,
  `Sources/CodexBarCore/PiSessionCostCache.swift`,
  `Sources/CodexBarCore/Vendored/CostUsage/*`
