---
summary: "Provider data sources and parsing overview (Codex, Claude, Gemini, Antigravity, Cursor, Droid/Factory, z.ai, Copilot, Kiro, Vertex AI)."
read_when:
  - Adding or modifying provider fetch/parsing
  - Adjusting provider labels, toggles, or metadata
  - Reviewing data sources for providers
---

# Providers

## Fetch strategies (current)
Legend: web (browser cookies/WebView), cli (RPC/PTy), oauth (API), api token, local probe, web dashboard.
Source labels (CLI/header): `openai-web`, `web`, `oauth`, `api`, `local`, plus provider-specific CLI labels (e.g. `codex-cli`, `claude`).

Cookie-based providers expose a Cookie source picker (Automatic or Manual) in Settings → Providers.

| Provider | Strategies (ordered for auto) |
| --- | --- |
| Codex | Web dashboard (`openai-web`) → CLI RPC/PTy (`codex-cli`); app uses CLI usage + optional dashboard scrape. |
| Claude | OAuth API (`oauth`) → Web API (`web`) → CLI PTY (`claude`). |
| Gemini | OAuth API via Gemini CLI credentials (`api`). |
| Antigravity | Local LSP/HTTP probe (`local`). |
| Cursor | Web API via cookies → stored WebKit session (`web`). |
| Droid/Factory | Web cookies → stored tokens → local storage → WorkOS cookies (`web`). |
| z.ai | API token (Keychain/env) → quota API (`api`). |
| MiniMax | Manual cookie header (Keychain/env) → browser cookies (+ local storage access token) → coding plan page (HTML) with remains API fallback (`web`). |
| Copilot | API token (device flow/env) → copilot_internal API (`api`). |
| Kiro | CLI command via `kiro-cli chat --no-interactive "/usage"` (`cli`). |
| Vertex AI | Google ADC OAuth (gcloud) → Cloud Monitoring quota usage (`oauth`). |

## Codex
- Web dashboard (when enabled): `https://chatgpt.com/codex/settings/usage` via WebView + browser cookies.
- CLI RPC default: `codex ... app-server` JSON-RPC (`account/read`, `account/rateLimits/read`).
- CLI PTY fallback: `/status` scrape.
- Local cost usage: scans `~/.codex/sessions/**/*.jsonl` (last 30 days).
- Status: Statuspage.io (OpenAI).
- Details: `docs/codex.md`.

## Claude
- OAuth API (preferred when CLI credentials exist).
- Web API (browser cookies) fallback when OAuth missing.
- CLI PTY fallback when OAuth + web are unavailable.
- Local cost usage: scans `~/.config/claude/projects/**/*.jsonl` (last 30 days).
- Status: Statuspage.io (Anthropic).
- Details: `docs/claude.md`.

## z.ai
- API token from Keychain or `Z_AI_API_KEY` env var.
- `GET https://api.z.ai/api/monitor/usage/quota/limit`.
- Status: none yet.
- Details: `docs/zai.md`.

## MiniMax
- Session cookie header from Keychain or `MINIMAX_COOKIE`/`MINIMAX_COOKIE_HEADER` env var.
- `GET https://platform.minimax.io/v1/api/openplatform/coding_plan/remains`.
- Status: none yet.
- Details: `docs/minimax.md`.

## Gemini
- OAuth-backed quota API (`retrieveUserQuota`) using Gemini CLI credentials.
- Token refresh via Google OAuth if expired.
- Tier detection via `loadCodeAssist`.
- Status: Google Workspace incidents (Gemini product).
- Details: `docs/gemini.md`.

## Antigravity
- Local Antigravity language server (internal protocol, HTTPS on localhost).
- `GetUserStatus` primary; `GetCommandModelConfigs` fallback.
- Status: Google Workspace incidents (Gemini product).
- Details: `docs/antigravity.md`.

## Cursor
- Web API via browser cookies (`cursor.com` + `cursor.sh`).
- Fallback: stored WebKit session.
- Status: Statuspage.io (Cursor).
- Details: `docs/cursor.md`.

## Droid (Factory)
- Web API via Factory cookies, bearer tokens, and WorkOS refresh tokens.
- Multiple fallback strategies (cookies → stored tokens → local storage → WorkOS cookies).
- Status: `https://status.factory.ai`.
- Details: `docs/factory.md`.

## Copilot
- GitHub device flow OAuth token + `api.github.com/copilot_internal/user`.
- Status: Statuspage.io (GitHub).
- Details: `docs/copilot.md`.

## Kiro
- CLI-based: runs `kiro-cli chat --no-interactive "/usage"` with 10s timeout.
- Parses ANSI output for plan name, monthly credits percentage, and bonus credits.
- Requires `kiro-cli` installed and logged in via AWS Builder ID.
- Status: AWS Health Dashboard (manual link, no auto-polling).
- Details: `docs/kiro.md`.

## Vertex AI
- OAuth credentials from `gcloud auth application-default login` (ADC).
- Quota usage via Cloud Monitoring `consumer_quota` metrics for `aiplatform.googleapis.com`.
- Token cost: scans `~/.claude/projects/` logs filtered to Vertex AI-tagged entries.
- Requires Cloud Monitoring API access in the current project.
- Details: `docs/vertexai.md`.
See also: `docs/provider.md` for architecture notes.
