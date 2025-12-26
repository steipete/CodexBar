---
summary: "Provider data sources and parsing overview (Codex, Claude, Gemini, Antigravity, Cursor, z.ai, Factory)."
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
- Fallback: stored session from "Add Account" WebKit login flow.
- Shows plan usage percentage, on-demand usage, and billing cycle reset.
- Supports Pro, Enterprise, Team, and Hobby membership types.
- Status: Statuspage.io (Cursor).
- Details in `docs/cursor.md`.

## Factory (Droid)
- Web-based: fetches usage from app.factory.ai API using WorkOS Bearer tokens.
- Token import: reads WorkOS refresh tokens from Chrome localStorage (LevelDB format).
- Token lifecycle: WorkOS refresh tokens are single-use; each exchange returns a new token that is stored for future use.
- Shows standard and premium token usage with billing cycle reset.
- Supports Enterprise, Team, and Pro tiers.
- Dashboard: `https://app.factory.ai/settings/billing`
- Status: no public status integration yet.
- Details in `docs/factory.md`.

See also: `docs/claude.md`, `docs/antigravity.md`, `docs/cursor.md`, `docs/factory.md`.
