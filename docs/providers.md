---
summary: "Provider data sources and parsing overview for every registered CodexBar provider."
read_when:
  - Adding or modifying provider fetch/parsing
  - Adjusting provider labels, toggles, or metadata
  - Reviewing data sources for providers
---

# Providers

CodexBar currently registers 48 provider IDs. Some companies expose multiple surfaces, such as Codex vs OpenAI API or
OpenCode vs OpenCode Go, because the auth source and quota shape differ.

## Fetch strategies (current)
Legend: web (browser cookies/WebView), cli (RPC/PTy or provider CLI), oauth (provider OAuth), api token, local probe, web dashboard.
Source labels (CLI/header): `openai-web`, `web`, `oauth`, `api`, `local`, `cli`, plus provider-specific CLI labels (e.g. `codex-cli`, `claude`).

Cookie-based providers expose a Cookie source picker (Automatic or Manual) in Settings → Providers.
Some browser cookie imports are cached in Keychain and reused until the session is invalid. API keys, manual cookie
headers, source selection, provider ordering, and token accounts are stored in `~/.codexbar/config.json`.

| Provider | Strategies (ordered for auto) |
| --- | --- |
| Codex | App Auto: OAuth API (`oauth`) → CLI RPC/PTy (`codex-cli`). CLI Auto: Web dashboard (`openai-web`) → CLI RPC/PTy (`codex-cli`). |
| OpenAI | Admin API key (`api`) for organization spend/usage; legacy API-key balance fallback. |
| Azure OpenAI | API key + endpoint + deployment probe (`api`) for deployment status validation. |
| Claude | Admin API key (`api`) when configured; otherwise App Auto: OAuth API (`oauth`) → CLI PTY (`claude`) → Web API (`web`). CLI Auto: Web API (`web`) → CLI PTY (`claude`). |
| Gemini | OAuth-backed API via Gemini CLI credentials (`api`). |
| Antigravity | Local LSP/HTTP probe (`local`). |
| Cursor | Web API via cookies → stored WebKit session (`web`). |
| OpenCode | Web dashboard via cookies (`web`). |
| OpenCode Go | Web dashboard via cookies (`web`); optional workspace ID. |
| Alibaba Coding Plan | Console RPC via web cookies (auto/manual) with API key fallback (`web`, `api`). |
| Alibaba Token Plan | Bailian subscription summary API via browser or manual cookies (`web`). |
| Droid/Factory | Web cookies → stored tokens → local storage → WorkOS cookies (`web`). |
| z.ai | API token from config/env → quota API (`api`). |
| Manus | Browser `session_id` cookie (auto/manual/env) → credits API (`web`). |
| MiniMax | Manual/browser session via Coding Plan web path (`web`), or Coding Plan API token (`api`). |
| Kimi | Auth token from `kimi-auth` cookie/manual token/env → usage API (`web`). |
| Kilo | API token from config/env → usage API (`api`); auto falls back to CLI session auth (`cli`). |
| Copilot | Device-flow/env/config token → `copilot_internal` API (`api`). |
| Kimi K2 (unofficial) | API key from config/env → legacy credit endpoint (`api`). |
| Kiro | CLI command via `kiro-cli chat --no-interactive "/usage"` (`cli`). |
| Vertex AI | Google ADC OAuth (gcloud) → Cloud Monitoring quota usage (`oauth`). |
| Augment | `auggie` CLI first, then browser-cookie web fallback (`cli`, `web`). |
| JetBrains AI | Local XML quota file (`local`). |
| Amp | Web settings page via browser cookies (`web`). |
| T3 Chat | Web tRPC customer-data endpoint via browser cookies (`web`). |
| Warp | API token (config/env) → GraphQL request limits (`api`). |
| ElevenLabs | API key from config/env → subscription usage API (`api`). |
| Windsurf | Web session bundle from browser localStorage (`web`) → local SQLite cache (`local`). |
| Ollama | API key verifies Cloud API access (`api`); browser cookies expose Cloud quota windows (`web`). |
| Synthetic | API key from config/env → quota API (`api`). |
| OpenRouter | API token (config, overrides env) → credits API (`api`). |
| Perplexity | Browser cookies/manual cookie/env session token → credits API (`web`). |
| Xiaomi MiMo | Browser cookies → balance/token plan endpoints (`web`). |
| Doubao | API key from config/env → Volcengine Ark chat-completions probe (`api`). |
| Abacus AI | Browser cookies → compute points + billing API (`web`). |
| Mistral | Console billing API via Ory Kratos session cookies (`web`). |
| DeepSeek | API key from env or token accounts → balance endpoint (`api`). |
| Moonshot | API key from config/env → balance endpoint (`api`). |
| Codebuff | API token from config/env or `codebuff login` credentials → usage API (`api`). |
| Crof | API key from config/env → credit balance + requests quota API (`api`). |
| Venice | API key from config/env → DIEM/USD balance API (`api`). |
| Command Code | Web billing API via Command Code session cookies (`web`). |
| StepFun | Username/password login or manual Oasis token (`web`). |
| AWS Bedrock | AWS credentials → Cost Explorer usage and budget tracking (`api`). |
| Grok | `grok agent stdio` JSON-RPC `x.ai/billing` (`cli`) → grok.com billing gRPC-web via Chrome session cookies (`web`); local `~/.grok/sessions` signals as fallback. |
| GroqCloud | API key → Prometheus metrics API for request/token/cache-hit rates (`api`). |
| LLM Proxy | API key + base URL → `/v1/quota-stats` aggregate proxy usage (`api`). |
| Deepgram | API key → project discovery and usage breakdown API (`api`). |

## Codex
- App Auto: OAuth API first; falls back to CLI only when OAuth credentials are missing or auth/refresh is invalid.
- Web dashboard (optional, off by default): `https://chatgpt.com/codex/settings/usage` via WebView + browser cookies.
- Battery saver toggle (currently off by default): reduces routine OpenAI web refreshes but still allows explicit manual refreshes.
- CLI RPC default: `codex ... app-server` JSON-RPC (`account/read`, `account/rateLimits/read`).
- CLI PTY: manual diagnostics/parser coverage only; automatic refresh does not launch bare Codex TUI.
- Local cost usage: scans `CODEX_HOME` (or `~/.codex`) `sessions` and sibling `archived_sessions` JSONL files for the configured history window.
- Status: Statuspage.io (OpenAI).
- Details: `docs/codex.md`.

## OpenAI
- API key from `~/.codexbar/config.json`, `OPENAI_ADMIN_KEY`, or `OPENAI_API_KEY`.
- Admin API keys are preferred and fetch organization costs plus completion usage for inline Today/7d/configured-window dashboards.
- Normal API keys fall back to the legacy credit-grants balance endpoint when organization usage is unavailable.
- Details: `docs/openai.md`.

## Azure OpenAI
- API key, endpoint, and deployment from `~/.codexbar/config.json` or `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, and `AZURE_OPENAI_DEPLOYMENT_NAME`.
- Validates the configured deployment with a minimal chat-completions request; it does not expose Azure spend or quota history.
- Use `AZURE_OPENAI_API_VERSION` to override the API version. Set it to `v1` for Azure's OpenAI-compatible v1 API path.
- Status: Azure status page link.

## Claude
- Admin API: `sk-ant-admin...` key in Settings/config, token accounts, or `ANTHROPIC_ADMIN_KEY`.
- Admin API shows organization spend/messages summaries with the same inline dashboard pattern as OpenAI API.
- App Auto: OAuth API (`oauth`) → CLI PTY (`claude`) → Web API (`web`).
- CLI Auto: Web API (`web`) → CLI PTY (`claude`).
- Local cost usage: scans `CLAUDE_CONFIG_DIR` when set, otherwise `~/.config/claude/projects` and `~/.claude/projects` JSONL files for the configured history window.
- Status: Statuspage.io (Anthropic).
- Details: `docs/claude.md`.

## z.ai
- API token from `~/.codexbar/config.json` (`providers[].apiKey`) or `Z_AI_API_KEY` env var.
- Supports global and BigModel CN quota hosts; override with `Z_AI_API_HOST` or `Z_AI_QUOTA_URL`.
- Status: none yet.
- Details: `docs/zai.md`.

## Manus
- Session token via browser `session_id` cookie, manual Settings entry, `MANUS_SESSION_TOKEN`, or `MANUS_COOKIE`.
- Credits endpoint: `POST https://api.manus.im/user.v1.UserService/GetAvailableCredits`.
- Auto mode prefers cached/browser cookies before env fallback; manual mode accepts either a bare `session_id` value or a full Cookie header.
- Status: none yet.

## MiniMax
- Coding Plan API token or web session from configured/manual/browser sources.
- Supports global and China mainland hosts via provider region settings and environment overrides.
- Web-session billing history can render 30-day token charts plus top model/method breakdowns when MiniMax exposes it.
- Status: none yet.
- Details: `docs/minimax.md`.

## Kimi
- Auth token (JWT from `kimi-auth` cookie) via manual entry or `KIMI_AUTH_TOKEN` env var.
- Shows weekly quota and 5-hour rate limit (300 minutes).
- Status: none yet.
- Details: `docs/kimi.md`.

## Kilo
- API token from `~/.codexbar/config.json` (`providers[].apiKey`) or `KILO_API_KEY`.
- Auto mode tries API first and falls back to CLI auth when API credentials are missing or unauthorized.
- CLI auth source: `~/.local/share/kilo/auth.json` (`kilo.access`), typically created by `kilo login`.
- Status: none yet.
- Details: `docs/kilo.md`.

## Kimi K2 (unofficial)
- API key via `~/.codexbar/config.json` or `KIMI_K2_API_KEY`/`KIMI_API_KEY` env var.
- Shows credit usage from the legacy `kimi-k2.ai` consumed/remaining totals.
- Use Moonshot / Kimi API for the official Kimi API account and billing surface.
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
- Status: none yet.
- Details: `docs/opencode.md`.

## OpenCode Go
- Web dashboard via browser cookies (`opencode.ai`).
- Uses the workspace Go page/server data for rolling 5-hour, weekly, and optional monthly usage windows.
- Optional workspace ID comes from `~/.codexbar/config.json` (`providers[].workspaceID`) or `CODEXBAR_OPENCODEGO_WORKSPACE_ID`.
- Status: none yet.
- Details: `docs/opencode.md`.

## Alibaba Coding Plan
- Web mode uses Alibaba console RPC with form payload + `sec_token`.
- Cookie sources: browser import (`auto`) or manual header (`cookieSource: manual`).
- API key fallback from Settings (`providers[].apiKey`) or `ALIBABA_CODING_PLAN_API_KEY` env var.
- Region hosts: international (`ap-southeast-1`) and China mainland (`cn-beijing`).
- Host overrides: `ALIBABA_CODING_PLAN_HOST` or `ALIBABA_CODING_PLAN_QUOTA_URL`.
- Status: `https://status.aliyun.com` (link only, no auto-polling).
- Details: `docs/alibaba-coding-plan.md`.

## Alibaba Token Plan
- Web mode posts to the Bailian `GetSubscriptionSummary` endpoint with form-encoded params and optional `sec_token`.
- Cookie sources: browser import (`auto`), manual Cookie header, or `ALIBABA_TOKEN_PLAN_COOKIE`.
- Default quota URL: `https://bailian.console.aliyun.com/data/api.json?action=GetSubscriptionSummary&product=BssOpenAPI-V3`.
- Host overrides: `ALIBABA_TOKEN_PLAN_HOST` or `ALIBABA_TOKEN_PLAN_QUOTA_URL`.
- Status: `https://status.aliyun.com` (link only, no auto-polling).
- Details: `docs/alibaba-token-plan.md`.

## Droid (Factory)
- Web API via Factory cookies, bearer tokens, and WorkOS refresh tokens.
- Multiple fallback strategies (cookies → stored tokens → local storage → WorkOS cookies).
- Status: `https://status.factory.ai`.
- Details: `docs/factory.md`.

## Copilot
- GitHub device flow OAuth token + `api.github.com/copilot_internal/user`.
- Supports multiple token accounts and account switching from provider settings/menu surfaces.
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
- Shows monthly credits usage and next refresh time.
- Status: none yet.
- Details: `docs/warp.md`.

## ElevenLabs
- API key from Settings, token accounts, `ELEVENLABS_API_KEY`, or `XI_API_KEY`.
- Reads `GET /v1/user/subscription` from `api.elevenlabs.io`.
- Shows character credit usage, reset timing, and voice slot usage when available.
- Override the API base URL with `ELEVENLABS_API_URL`.
- Status: `https://status.elevenlabs.io` (link only, no auto-polling).
- Details: `docs/elevenlabs.md`.

## Vertex AI
- OAuth credentials from `gcloud auth application-default login` (ADC).
- Quota usage via Cloud Monitoring `consumer_quota` metrics for `aiplatform.googleapis.com`.
- Token cost: uses the Claude local-log scanner filtered to Vertex AI-tagged entries.
- Requires Cloud Monitoring API access in the current project.
- Details: `docs/vertexai.md`.

## JetBrains AI
- Local XML quota file from IDE configuration directory.
- Auto-detects installed JetBrains IDEs; uses most recently used.
- Reads `AIAssistantQuotaManager2.xml` for monthly credits and refill date.
- Status: none (no status page).
- Details: `docs/jetbrains.md`.

## Augment
- Auto mode tries the `auggie` CLI first.
- Web fallback uses browser cookies, with manual cookie header support.
- Tracks credit usage and account/subscription data where available.
- Status: none yet.
- Details: `docs/augment.md`.

## Amp
- Web settings page (`https://ampcode.com/settings`) via browser cookies.
- Parses Amp Free usage from the settings HTML.
- Status: none yet.
- Details: `docs/amp.md`.

## T3 Chat
- Web tRPC endpoint (`https://t3.chat/api/trpc/getCustomerData`) via browser cookies.
- Parses JSONL response lines and extracts customer data from the embedded tRPC payload.
- Shows the 4-hour Base bucket and monthly Overage bucket documented in the T3 Chat FAQ.
- Status: none yet.

## Ollama
- Web settings page (`https://ollama.com/settings`) via browser cookies.
- Parses Cloud Usage plan badge, session/weekly usage, and reset timestamps.
- Status: none yet.
- Details: `docs/ollama.md`.

## Synthetic
- API key from `~/.codexbar/config.json` (`providers[].apiKey`) or `SYNTHETIC_API_KEY`.
- Shows rolling five-hour, weekly token, search-hourly, and cost/credit quota lanes when present.
- Status: none yet.

## OpenRouter
- API token from `~/.codexbar/config.json` (`providers[].apiKey`) or `OPENROUTER_API_KEY` env var.
- Reads credits and key rate-limit info from OpenRouter APIs.
- Shows daily, weekly, and monthly API-key spend when `/api/v1/key` returns those fields.
- Override base URL with `OPENROUTER_API_URL` env var.
- Status: `https://status.openrouter.ai` (link only, no auto-polling yet).
- Details: `docs/openrouter.md`.

## Perplexity
- Browser session cookie from automatic import, manual header/token, or `PERPLEXITY_SESSION_TOKEN` / `PERPLEXITY_COOKIE`.
- Tracks recurring credits, bonus/promotional credits, purchased credits, and renewal date when present.
- Status: `https://status.perplexity.com/` (link only, no auto-polling).

## Xiaomi MiMo
- Browser cookies from automatic import or manual `Cookie:` header.
- Reads balance and token-plan usage from `platform.xiaomimimo.com`.
- Status: none yet.
- Details: `docs/mimo.md`.

## Doubao
- API key via `ARK_API_KEY`, `VOLCENGINE_API_KEY`, `DOUBAO_API_KEY`, or provider config.
- Probes Volcengine Ark chat completions and reads request rate-limit headers when present.
- Status: none yet.
- Details: `docs/doubao.md`.

## Abacus AI
- Browser cookies (`abacus.ai`, `apps.abacus.ai`) via automatic import or manual header.
- Reads organization compute points and billing data.
- Shows monthly credit gauge with pace tick and reserve/deficit estimate.
- Status: none yet.
- Details: `docs/abacus.md`.

## Mistral
- Session cookie (`ory_session_*`) from browser auto-import or manual `Cookie:` header.
- CSRF token (`csrftoken` cookie) sent as `X-CSRFTOKEN` header.
- Domain: `admin.mistral.ai`.
- Reads monthly usage and pricing from the Mistral billing API.
- Cost is computed client-side from token counts and response pricing.
- Resets at end of calendar month.
- Status: `https://status.mistral.ai` (link only, no auto-polling).

## DeepSeek
- API key via `DEEPSEEK_API_KEY` / `DEEPSEEK_KEY` env var or DeepSeek token accounts.
- Shows total balance with paid vs. granted breakdown; USD preferred when multiple currencies present.
- Status: `https://status.deepseek.com` (link only, no auto-polling).
- Details: `docs/deepseek.md`.

## Moonshot / Kimi API
- API key via `MOONSHOT_API_KEY` / `MOONSHOT_KEY` env var or provider config.
- Reads `GET /v1/users/me/balance` from the selected Moonshot region.
- Region: international (`api.moonshot.ai`) or China mainland (`api.moonshot.cn`), configurable in Settings or `MOONSHOT_REGION`.
- Shows available balance; negative cash balance is surfaced as a deficit.
- Status: none yet.
- Details: `docs/moonshot.md`.

## Venice
- API key via `VENICE_API_KEY` / `VENICE_KEY` env var or Venice token accounts.
- Shows current DIEM or USD balance; DIEM epoch allocation progress when available.
- Status: none yet.
- Details: `docs/venice.md`.

## Codebuff
- API token from `~/.codexbar/config.json`, `CODEBUFF_API_KEY`, or `~/.config/manicode/credentials.json` created by `codebuff login`.
- Reads usage and subscription data from Codebuff APIs.
- Shows credit balance, weekly rate limit, reset timing, subscription status, and auto-top-up flag when present.
- Override base URL with `CODEBUFF_API_URL`.
- Status: none yet.
- Details: `docs/codebuff.md`.

## Crof
- API key from `~/.codexbar/config.json`, `CROF_API_KEY`, or `CROFAI_API_KEY`.
- Reads `credits`, `requests_plan`, and `usable_requests` from `GET https://crof.ai/usage_api/`.
- Shows request quota as the primary usage window and dollar credits as the secondary row.
- Infers the daily request reset from midnight America/Chicago until the usage API exposes reset metadata.
- Status: none yet.
- Details: `docs/crof.md`.

## Command Code
- Browser session cookies from automatic import or manual `Cookie:` header.
- Reads monthly USD credits and billing-cycle usage from `api.commandcode.ai`.
- Automatic import looks for better-auth session cookies from `commandcode.ai` / `www.commandcode.ai`.
- Status: none yet.
- Details: `docs/command-code.md`.

## Grok
- `grok agent stdio` (ACP) JSON-RPC `x.ai/billing` method; requires `grok login` (SuperGrok OAuth/OIDC).
- Reads cached credentials from `~/.grok/auth.json` for identity (email, team).
- Falls back to grok.com's billing gRPC-web endpoint via Chrome session cookies when the CLI does not expose billing.
- CLI/test runs do not import browser cookies unless `CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT=1` is set.
- Local fallback aggregates `~/.grok/sessions/**/signals.json` token counts when the RPC is unavailable.
- Status: link only to `https://status.x.ai` (no auto-polling yet).
- Details: `docs/grok.md`.

## AWS Bedrock
- AWS credentials from `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optional `AWS_SESSION_TOKEN`.
- Region from `AWS_REGION` / `AWS_DEFAULT_REGION`, defaulting to `us-east-1`.
- Reads AWS Cost Explorer for Bedrock spend and can compare usage against `CODEXBAR_BEDROCK_BUDGET`.
- Override Cost Explorer base URL with `CODEXBAR_BEDROCK_API_URL` for tests.
- Details: `docs/bedrock.md`.

## Deepgram
- API key from config or `DEEPGRAM_API_KEY`.
- Optional project ID from provider settings or `DEEPGRAM_PROJECT_ID`; otherwise aggregates all visible projects.
- Reads Deepgram usage breakdowns for audio hours, agent hours, token totals, TTS characters, and requests.
- Details: `docs/deepgram.md`.

## StepFun
- Username/password login or manual Oasis-Token.
- Reads Step Plan 5-hour and weekly rate-limit windows from `platform.stepfun.com`.
- Shows subscription plan name when the Step Plan status API returns one.
- Status: none yet.
- Details: `docs/stepfun.md`.

See also: `docs/provider.md` for architecture notes.
