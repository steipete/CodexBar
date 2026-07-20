---
summary: "Codex provider data sources: OpenAI web dashboard, Codex CLI RPC, credits, and local cost usage."
read_when:
  - Debugging Codex usage/credits parsing
  - Updating OpenAI dashboard scraping or cookie import
  - Changing Codex CLI RPC or diagnostic PTY behavior
  - Reviewing local cost usage scanning
---

# Codex provider

Codex has three automatic usage data paths (OAuth API, web dashboard, CLI RPC) plus a manual CLI PTY diagnostic parser and a local cost-usage scanner.
The OAuth API is the default app source when credentials are available; web access is optional for dashboard extras.

## Data sources + fallback order

### App default selection (debug menu disabled)
1) OAuth API (auth.json credentials).
2) CLI RPC through `codex app-server`.
3) If OpenAI web extras are enabled and a matching OpenAI web session is available (Automatic or Manual cookies),
   dashboard extras load as a separate follow-up refresh and the source label becomes `primary + openai-web`.

Usage source picker:
- Preferences → Providers → Codex → Usage source (Auto/OAuth/CLI).

### CLI default selection (`--source auto`)
1) OpenAI web dashboard (when available).
2) Codex CLI RPC through `codex app-server`.

### OAuth API (preferred for the app)
- Reads OAuth tokens from `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`).
- Refreshes access tokens when `last_refresh` is older than 8 days.
- Calls `GET https://chatgpt.com/backend-api/wham/usage` (default) with `Authorization: Bearer <token>`.
- The app reads reset-credit inventory once per refresh with a best-effort
  `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` using the same account-scoped OAuth context;
  the CLI requests it only when optional credits are included.
- The menu and provider settings list every still-available expiry, while the optional credits setting controls
  nearing-expiry notifications. CodexBar does not redeem or modify reset credits.
- `rate_limit.primary_window` / `secondary_window` map to the session/weekly lanes.
- `additional_rate_limits[]` (model-specific limits such as GPT-5.3-Codex-Spark) map to named
  `UsageSnapshot.extraRateWindows` entries. Spark uses stable `codex-spark` / `codex-spark-weekly` ids and
  `Codex Spark 5-hour` / `Codex Spark Weekly` titles. When the field is absent, the snapshot is unchanged.
- Preferences → Providers → Codex → Show Codex Spark usage hides only the Spark rows in menus and the provider
  preview. It does not change fetching, history, notifications, widgets, credits, or other extra limits.

### Advanced profile-home accounts
- Managed Codex accounts remain the default multi-account path.
- Advanced users can add existing Codex homes to `~/.codexbar/config.json` with
  `providers[].codexProfileHomePaths`.
- Each configured path must be absolute or start with `~/`, and point at a Codex home that contains `auth.json`.
- CodexBar reads identity from the configured home, exposes it in the Codex account switcher, and scopes
  remote Codex fetches with `CODEX_HOME`.
- Profile homes are not copied, reauthenticated, or removed by CodexBar.

Example:

```json
{
  "id": "codex",
  "codexProfileHomePaths": [
    "~/.codex-work",
    "~/.codex-personal"
  ]
}
```

### OpenAI web dashboard (optional, off by default)
- Enable it in Preferences -> Providers -> Codex -> OpenAI web extras.
- It exists for dashboard-only extras such as code review remaining, usage breakdown, and credits history.
- It is intentionally opt-in because it loads `chatgpt.com` in a hidden WebView and can materially increase battery or network usage.
- OpenAI web battery saver is a separate toggle. When enabled, routine background/settings-driven refreshes are reduced, but explicit manual refreshes still run.
- OpenAI web battery saver currently defaults to off.
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

### Codex CLI RPC (automatic CLI source)
- Launches local RPC server: `codex -s read-only -a untrusted app-server`.
- JSON-RPC over stdin/stdout:
  - `initialize` (client name/version)
  - `account/read`
  - `account/rateLimits/read`
- RPC reads are bounded: initialization has a longer startup budget, and normal requests have a shorter per-method
  timeout. On timeout, CodexBar terminates the child `codex app-server` process so the stdout reader unwinds instead
  of leaving refresh stuck indefinitely.
- Provides:
  - Usage windows (primary + secondary) with reset timestamps.
  - Credits snapshot (balance, hasCredits, unlimited).
  - Account identity (email + plan type) when available.
- App-server errors are terminal for the CLI strategy, except when Codex includes a recoverable `wham/usage` JSON body in the error text.
- If macOS blocks or quarantines the `codex` executable, CodexBar records the launch failure and skips background CLI
  launches for 30 minutes. Use a manual refresh after reinstalling or unblocking `codex` to retry immediately.
- CodexBar also discovers the Codex CLI bundled with current ChatGPT and legacy Codex desktop apps, even when `codex`
  is absent from the shell PATH.
- If managed Codex account login still reports a missing executable, turn on **Show debug settings** in
  **Settings > Advanced**, then check **Settings > Debug > CLI Paths**. When no Codex binary appears there, confirm
  `codex --version` works in Terminal, check `which -a codex` for stale duplicate installs, then run
  `npm install -g --include=optional @openai/codex@latest` before retrying Add Account.

### Codex CLI PTY diagnostics (`/status`)
- Manual/debug parser only; automatic background refresh and `CodexBarCLI usage --source cli` do not launch bare Codex TUI.
- Kept for explicit diagnostics/parser coverage because bare `codex` TUI can start interactive auth and open browser tabs.
- Parses rendered `/status` output:
  - `Credits:` line
  - `5h limit` line → percent + reset text
  - `Weekly limit` line → percent + reset text
- Detects update prompts and surfaces a "CLI update needed" error.

## Account identity resolution (for web matching)
1) Latest Codex usage snapshot (from RPC, if available).
2) `~/.codex/auth.json` (JWT claims: email + plan).
3) OpenAI dashboard signed-in email (cached).
4) Last imported browser cookie email (cached).

## Credits
- Web dashboard fills credits only when OAuth/CLI do not provide them.
- CLI RPC: `account/rateLimits/read` → credits balance.
- CLI PTY diagnostics can still parse `Credits:` from saved/manual `/status` output.

## Cost usage (local log scan)
- Menu source selection:
  - By default, a selected managed account keeps its own `CODEX_HOME` session history.
  - **Local session cost estimates** is a Codex-only opt-in that instead scans this Mac's ambient `$CODEX_HOME`
    (or `~/.codex`) independently of quota, OAuth, web-dashboard, and administrator access.
  - The local-only mode never makes a network request or uploads session content. It uses an existing local models.dev
    cache when available, then the bundled `CostUsagePricing` rates.
- Source files:
  - Native Codex logs:
    - `~/.codex/sessions/YYYY/MM/DD/*.jsonl`
    - `~/.codex/archived_sessions/*.jsonl` (flat; date inferred from filename when present)
    - Or `$CODEX_HOME/sessions/...` + `$CODEX_HOME/archived_sessions/...` if `CODEX_HOME` is set.
  - Supported pi-compatible sessions:
    - `~/.pi/agent/sessions/**/*.jsonl`
    - `~/.omp/agent/sessions/**/*.jsonl`
- Scanner:
  - Native Codex logs parse `event_msg` token_count entries and `turn_context` model markers; when both are present,
    `turn_context` is authoritative for the model bucket.
  - pi and OMP sessions count assistant-message usage rows and attribute `openai-codex` assistant usage to Codex.
  - pi-compatible assistant usage is bucketed by assistant-turn timestamp, so mixed-model sessions can contribute to
    multiple days/models correctly.
  - Matching assistant entry IDs within the same session are counted once across roots; distinct turns are retained.
  - Native conversation rows reuse the corrected cached per-file totals and existing pricing tables. They are hidden
    when pi-compatible usage joins the aggregate because the native-only rows would not reconcile with the merged total.
- Cache:
  - Native + merged provider cache: `~/Library/Caches/CodexBar/cost-usage/codex-v10.json`
  - pi-compatible session cache: `~/Library/Caches/CodexBar/cost-usage/pi-sessions-v7.json`
- Window: configurable 1-365 day rolling history, with a 60s minimum refresh interval.

### Usage & Spend account rows

Settings → Usage & Spend performs a separate fixed 30-day scan for every visible Codex account. Each request freezes
the account source, exact Codex home, authentication fingerprint, and cache identity before scanning. A missing or
invalid home is omitted; it never falls back to ambient `~/.codex` or to the global Codex token snapshot.

These account rows intentionally exclude pi and OMP sessions because their history is machine-local rather than owned
by one Codex account. The normal Codex cost menu and CLI scan continue to include supported pi-compatible history. The
dashboard labels its values as local estimates and keeps currencies separate.

## Key files
- Web: `Sources/CodexBarCore/OpenAIWeb/*`
- CLI RPC + diagnostic PTY parser: `Sources/CodexBarCore/UsageFetcher.swift`,
  `Sources/CodexBarCore/Providers/Codex/CodexStatusProbe.swift`
- Cost usage: `Sources/CodexBarCore/CostUsageFetcher.swift`,
  `Sources/CodexBarCore/PiSessionCostScanner.swift`,
  `Sources/CodexBarCore/PiSessionCostCache.swift`,
  `Sources/CodexBarCore/Vendored/CostUsage/*`
