---
summary: "Codex provider data sources: OpenAI web dashboard, Codex CLI RPC/PTY, credits, and local cost usage."
read_when:
  - Debugging Codex usage/credits parsing
  - Updating OpenAI dashboard scraping or cookie import
  - Changing Codex CLI RPC/PTY behavior
  - Reviewing local cost usage scanning
---

# Codex provider

Codex has four usage data paths (OAuth API, web dashboard, CLI RPC, CLI PTY) plus a local cost-usage scanner.
The OAuth API is the default app source when credentials are available; web access is optional for dashboard extras.

## Data sources + fallback order

### App default selection (debug menu disabled)
1) OAuth API (auth.json credentials).
2) CLI RPC, with CLI PTY fallback when needed.
3) If OpenAI cookies are enabled (Automatic or Manual), dashboard extras load in parallel and the source label becomes
   `primary + openai-web`.

Usage source picker:
- Preferences → Providers → Codex → Usage source (Auto/OAuth/CLI).

### CLI default selection (`--source auto`)
1) OpenAI web dashboard (when available).
2) Codex CLI RPC, with CLI PTY fallback when needed.

### OAuth API (preferred for the app)
- Reads OAuth tokens from `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`).
- Refreshes access tokens when `last_refresh` is older than 8 days.
- Calls `GET https://chatgpt.com/backend-api/wham/usage` (default) with `Authorization: Bearer <token>`.

### OpenAI web dashboard (optional)
- Preferences → Providers → Codex → OpenAI cookies (Automatic or Manual).
- URL: `https://chatgpt.com/codex/settings/usage`.
- Uses an off-screen `WKWebView` with a per-account `WKWebsiteDataStore`.
  - Store key: deterministic UUID from the normalized email.
- WebKit store can hold multiple accounts concurrently.
- Cookie import (Automatic mode, when WebKit store has no matching session or login required):
  1) Safari: `~/Library/Cookies/Cookies.binarycookies`
  2) Chrome/Chromium forks: `~/Library/Application Support/Google/Chrome/*/Cookies`
  3) Firefox: `~/Library/Application Support/Firefox/Profiles/*/cookies.sqlite`
  - Domains loaded: `chatgpt.com`, `openai.com`.
  - No cookie-name filter; we import all matching domain cookies.
- Cached cookies: Keychain cache `com.steipete.codexbar.cache` (account `cookie.codex`, source + timestamp).
  Reused before re-importing from browsers.
- Manual cookie header:
  - Paste the `Cookie:` header from a `chatgpt.com` request in Preferences → Providers → Codex.
  - Used when OpenAI cookies are set to Manual.
- Account match:
  - Signed-in email extracted from `client-bootstrap` JSON in HTML (or `__NEXT_DATA__`).
  - If Codex email is known and does not match, the web path is rejected.
- Web scrape payload (via `OpenAIDashboardScrapeScript` + `OpenAIDashboardParser`):
  - Rate limits (5h + weekly) parsed from body text.
  - Credits remaining parsed from body text.
  - Code review remaining (%).
  - Usage breakdown chart (Recharts bar data + legend colors).
  - Credits usage history table rows.
  - Credits purchase URL (best-effort).
- Errors surfaced:
  - Login required or Cloudflare interstitial.

### Codex CLI RPC (default CLI fallback)
- Launches local RPC server: `codex -s read-only -a untrusted app-server`.
- JSON-RPC over stdin/stdout:
  - `initialize` (client name/version)
  - `account/read`
  - `account/rateLimits/read`
- Provides:
  - Usage windows (primary + secondary) with reset timestamps.
  - Credits snapshot (balance, hasCredits, unlimited).
  - Account identity (email + plan type) when available.

### Codex CLI PTY fallback (`/status`)
- Runs `codex` in a PTY via `TTYCommandRunner`.
- Default behavior: exit after each probe; Debug → "Keep CLI sessions alive" keeps it running between probes.
- Sends `/status`, parses the rendered screen:
  - `Credits:` line
  - `5h limit` line → percent + reset text
  - `Weekly limit` line → percent + reset text
- Retry once with a larger terminal size on parse failure (short retry window).
- Do not retry on timeout; timed-out probes fail fast and wait for the next refresh cycle.
- Detects update prompts and surfaces a "CLI update needed" error.

## Account identity resolution (for web matching)
1) Latest Codex usage snapshot (from RPC, if available).
2) `~/.codex/auth.json` (JWT claims: email + plan).
3) OpenAI dashboard signed-in email (cached).
4) Last imported browser cookie email (cached).

## Credits
- Web dashboard fills credits only when OAuth/CLI do not provide them.
- CLI RPC: `account/rateLimits/read` → credits balance.
- CLI PTY fallback: parse `Credits:` from `/status`.

## Cost usage (local log scan)
- Source files:
  - `~/.codex/sessions/YYYY/MM/DD/*.jsonl`
  - `~/.codex/archived_sessions/*.jsonl` (flat; date inferred from filename when present)
  - Or `$CODEX_HOME/sessions/...` + `$CODEX_HOME/archived_sessions/...` if `CODEX_HOME` is set.
- Scanner:
  - Parses `event_msg` token_count entries and `turn_context` model markers.
  - Computes input/cached/output token deltas and per-model cost.
- Cache:
  - `~/Library/Caches/CodexBar/cost-usage/codex-v1.json`
- Window: last 30 days (rolling), with a 60s minimum refresh interval.

## Key files
- Web: `Sources/CodexBarCore/OpenAIWeb/*`
- CLI RPC + PTY: `Sources/CodexBarCore/UsageFetcher.swift`,
  `Sources/CodexBarCore/Providers/Codex/CodexStatusProbe.swift`
- Cost usage: `Sources/CodexBarCore/CostUsageFetcher.swift`,
  `Sources/CodexBarCore/Vendored/CostUsage/*`
