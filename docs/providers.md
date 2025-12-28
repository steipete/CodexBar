---
summary: "Provider data sources and parsing overview (Codex, Claude, Gemini, Antigravity, Cursor, Copilot, Windsurf, Droid/Factory)."
read_when:
  - Adding or modifying provider fetch/parsing
  - Adjusting provider labels, toggles, or metadata
  - Reviewing data sources for providers
---

# Providers

## Codex
- Primary (when OpenAI web enabled): OpenAI web dashboard for usage limits + credits.
- CLI fallback only when no matching web cookies (RPC for 5-hour + weekly limits and credits).
- Secondary fallback: PTY scrape of `codex /status` if RPC unavailable.
- Account identity: prefer web when enabled; otherwise RPC; fall back to `~/.codex/auth.json`.
- OpenAI web integration uses browser cookies and can replace CLI data (see `docs/web-integration.md`).
- Status: Statuspage.io (OpenAI).

## Claude
- Primary: Claude web API (cookies).
- CLI fallback only when no Claude web cookies are found.
- Debug-only override: OAuth usage API (`https://api.anthropic.com/api/oauth/usage`) using Claude CLI credentials
  (keychain first, then `~/.claude/.credentials.json`).
- Optional (debug): web cookie enrichment for Extra usage spend/limit when the CLI source is forced (see `docs/claude.md`).
- Handles Sonnet-only weekly bar when present; legacy Opus label fallback.
- Status: Statuspage.io (Anthropic).

## z.ai
- API: `https://api.z.ai/api/monitor/usage/quota/limit` using an API token stored in Keychain (Preferences → Providers → z.ai).
- Shows token and MCP usage windows from the quota limits response.
- Dashboard: `https://z.ai/manage-apikey/subscription`
- Status: no public status integration yet.

## Gemini
- CLI `/stats` parsing for quota; OAuth-backed API fetch for plan/limits.
- Status: Google Workspace incidents for the Gemini product.

## Antigravity
- Local Antigravity language server probe; internal protocol, conservative parsing.
- Status: Google Workspace incidents for Gemini (same product feed).
- Details in `docs/antigravity.md`.

## Cursor
- Web-based: fetches usage from cursor.com API using browser session cookies.
- Cookie import: Safari (Cookies.binarycookies) → Chrome (encrypted SQLite DB) → Firefox (cookies.sqlite); requires cursor.com + cursor.sh cookies.
- Linux: Chrome cookie import supported; sign in to cursor.com in Chrome.
- Fallback: stored session from "Add Account" WebKit login flow (macOS) or `CURSOR_COOKIE_HEADER` env var (Linux).
- Shows plan usage percentage, on-demand usage, and billing cycle reset.
- Supports Pro, Enterprise, Team, and Hobby membership types.
- Status: Statuspage.io (Cursor).
- Details in `docs/cursor.md`.

## GitHub Copilot
- Web-based: fetches usage from `github.com/settings/copilot` using browser session cookies.
- Cookie import: Safari → Chrome → Firefox (macOS); Chrome only on Linux.
- Parses premium requests usage percentage and monthly reset timing.
- Shows account login and active plan when available.
- Status: status page at `https://www.githubstatus.com`.

## Windsurf
- Firebase-based: fetches usage from Windsurf's Firebase backend using access tokens.
- Token sources: `WINDSURF_TOKEN` environment variable, or auto-extracted from Chrome's IndexedDB.
- Linux: requires `pysqlite3` or manual token extraction via browser DevTools.
- Shows credits usage (in cents) with usage percentage and reset timing.
- Auto-retries token extraction when stored tokens expire.
- Status: no public status integration yet.

## Droid (Factory)
- Web-based: fetches usage from app.factory.ai (and auth/api hosts when needed) using browser session cookies or WorkOS refresh tokens from local storage.
- Cookie import: Safari → Chrome → Firefox; requires factory.ai/app.factory.ai cookies (plus ChatGPT Atlas browser data when installed).
- Fallback: stored session cookies persisted by CodexBar.
- Shows Standard + Premium usage and billing period reset.
- Status: status page at `https://status.factory.ai`.

See also: `docs/claude.md`, `docs/antigravity.md`, `docs/cursor.md`.
