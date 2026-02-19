---
summary: "Provider data sources and parsing overview (Codex, Claude, Gemini, Antigravity, Cursor, Droid/Factory, z.ai, Copilot, Kimi, Kimi K2, Kiro, Warp, Vertex AI, Augment, Amp, Ollama, JetBrains AI, OpenRouter)."
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
Browser cookie imports are cached in Keychain (`com.steipete.codexbar.cache`, account `cookie.<provider>`) and reused
until the session is invalid, to avoid repeated Keychain prompts.

| Provider | Strategies (ordered for auto) |
| --- | --- |
| Codex | Web dashboard (`openai-web`) → CLI RPC/PTy (`codex-cli`); app uses CLI usage + optional dashboard scrape. |
| Claude | App Auto: OAuth API (`oauth`) → CLI PTY (`claude`) → Web API (`web`). CLI Auto: Web API (`web`) → CLI PTY (`claude`). |
| Gemini | OAuth API via Gemini CLI credentials (`api`). |
| Antigravity | Local LSP/HTTP probe (`local`). |
| Cursor | Web API via cookies → stored WebKit session (`web`). |
| OpenCode | Web dashboard via cookies (`web`). |
| Droid/Factory | Web cookies → stored tokens → local storage → WorkOS cookies (`web`). |
| z.ai | API token (Keychain/env) → quota API (`api`). |
| MiniMax | Manual cookie header (Keychain/env) → browser cookies (+ local storage access token) → coding plan page (HTML) with remains API fallback (`web`). |
| Kimi | API token (JWT from `kimi-auth` cookie) → usage API (`api`). |
| Copilot | API token (device flow/env) → copilot_internal API (`api`). |
| Kimi K2 | API key (Keychain/env) → credit endpoint (`api`). |
| Kiro | CLI command via `kiro-cli chat --no-interactive "/usage"` (`cli`). |
| Vertex AI | Google ADC OAuth (gcloud) → Cloud Monitoring quota usage (`oauth`). |
| JetBrains AI | Local XML quota file (`local`). |
| Amp | Web settings page via browser cookies (`web`). |
| Warp | API token (config/env) → GraphQL request limits (`api`). |
| Ollama | Web settings page via browser cookies (`web`). |
| OpenRouter | API token (config, overrides env) → credits API (`api`). |

## Codex
- Web dashboard (when enabled): `https://chatgpt.com/codex/settings/usage` via WebView + browser cookies.
- CLI RPC default: `codex ... app-server` JSON-RPC (`account/read`, `account/rateLimits/read`).
- CLI PTY fallback: `/status` scrape.
- Local cost usage: scans `~/.codex/sessions/**/*.jsonl` (last 30 days).
- Status: Statuspage.io (OpenAI).
- Details: `docs/codex.md`.

## Claude
- App Auto: OAuth API (`oauth`) → CLI PTY (`claude`) → Web API (`web`).
- CLI Auto: Web API (`web`) → CLI PTY (`claude`).
- Local cost usage: scans `~/.config/claude/projects/**/*.jsonl` (last 30 days).
- Status: Statuspage.io (Anthropic).
- Details: `docs/claude.md`.

## z.ai
- API token from Keychain or `Z_AI_API_KEY` env var.
- Quota endpoint: `https://api.z.ai/api/monitor/usage/quota/limit` (global) or `https://open.bigmodel.cn/api/monitor/usage/quota/limit` (BigModel CN); override with `Z_AI_API_HOST` or `Z_AI_QUOTA_URL`.
- Status: none yet.
- Details: `docs/zai.md`.

## MiniMax
- Session cookie header from Keychain or `MINIMAX_COOKIE`/`MINIMAX_COOKIE_HEADER` env var.
- Hosts: `platform.minimax.io` (global) or `platform.minimaxi.com` (China mainland) via region picker or `MINIMAX_HOST`; full overrides via `MINIMAX_CODING_PLAN_URL` / `MINIMAX_REMAINS_URL`.
- `GET {host}/v1/api/openplatform/coding_plan/remains`.
- Status: none yet.
- Details: `docs/minimax.md`.

## Kimi
- Auth token (JWT from `kimi-auth` cookie) via manual entry or `KIMI_AUTH_TOKEN` env var.
- `POST https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages`.
- Shows weekly quota and 5-hour rate limit (300 minutes).
- Status: none yet.
- Details: `docs/kimi.md`.

## Kimi K2
- API key via Settings (Keychain) or `KIMI_K2_API_KEY`/`KIMI_API_KEY` env var.
- `GET https://kimi-k2.ai/api/user/credits`.
- Shows credit usage based on consumed/remaining totals.
- Status: none yet.
- Details: `docs/kimi-k2.md`.

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

## OpenCode
- Web dashboard via browser cookies (`opencode.ai`).
- `POST https://opencode.ai/_server` (workspaces + subscription usage).
- Status: none yet.
- Details: `docs/opencode.md`.

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

## Warp
- API token from Settings or `WARP_API_KEY` / `WARP_TOKEN` env var.
- GraphQL credit limits: `https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo`.
- Shows monthly credits usage and next refresh time.
- Status: none yet.
- Details: `docs/warp.md`.

## Vertex AI
- OAuth credentials from `gcloud auth application-default login` (ADC).
- Quota usage via Cloud Monitoring `consumer_quota` metrics for `aiplatform.googleapis.com`.
- Token cost: scans `~/.claude/projects/` logs filtered to Vertex AI-tagged entries.
- Requires Cloud Monitoring API access in the current project.
- Details: `docs/vertexai.md`.
## JetBrains AI
- Local XML quota file from IDE configuration directory.
- Auto-detects installed JetBrains IDEs; uses most recently used.
- Reads `AIAssistantQuotaManager2.xml` for monthly credits and refill date.
- Status: none (no status page).
- Details: `docs/jetbrains.md`.

## Amp
- Web settings page (`https://ampcode.com/settings`) via browser cookies.
- Parses Amp Free usage from the settings HTML.
- Status: none yet.
- Details: `docs/amp.md`.

## Ollama
- Web settings page (`https://ollama.com/settings`) via browser cookies.
- Parses Cloud Usage plan badge, session/weekly usage, and reset timestamps.
- Status: none yet.
- Details: `docs/ollama.md`.

## OpenRouter
- API token from `~/.codexbar/config.json` (`providerConfig.openrouter.apiKey`) or `OPENROUTER_API_KEY` env var.
- Credits endpoint: `https://openrouter.ai/api/v1/credits` (returns total credits purchased and usage).
- Key info endpoint: `https://openrouter.ai/api/v1/key` (returns rate limit info).
- Override base URL with `OPENROUTER_API_URL` env var.
- Status: `https://status.openrouter.ai` (link only, no auto-polling yet).
- Details: `docs/openrouter.md`.

See also: `docs/provider.md` for architecture notes.
