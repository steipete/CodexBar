---
summary: "Antigravity provider notes: OAuth usage, multi-account switching, local LSP probing, and quota parsing."
read_when:
  - Adding or modifying the Antigravity provider
  - Debugging Antigravity port detection or quota parsing
  - Adjusting Antigravity menu labels or model mapping
  - Working with Antigravity OAuth or account switching
---

# Antigravity provider

For Google individual, AI Pro, and Ultra accounts blocked by the June 2026 Gemini CLI OAuth
shutdown, Antigravity is the replacement path for Gemini quota tracking in CodexBar. Launch
the Antigravity app or run `agy`, sign in, then refresh. See `docs/gemini.md` for the Gemini
provider migration notes. CodexBar offers the handoff only after an observed Google migration
signal and never enables or falls back to Antigravity automatically.

Antigravity supports four usage data sources:

1. The Antigravity 2.0 app's local `language_server` (preferred when the app is open).
2. The `agy` CLI's embedded HTTPS localhost server (preferred over the IDE because it exposes richer quota data).
3. The Antigravity IDE extension `language_server` (used after `agy` CLI because current IDE local payloads only expose session/model quota data).
4. Google OAuth-backed remote usage (explicit OAuth mode, and the account-scoped fallback used for multi-account switching). The OAuth path can store multiple Google accounts through the shared token-account switcher.

The local and CLI paths both prefer Antigravity's internal `RetrieveUserQuotaSummary` quota payload and may fall back to
`GetUserStatus`, then `GetCommandModelConfigs`; CodexBar never scrapes the desktop UI or the `agy` TUI.

As of Antigravity 2.x, the Antigravity app and `agy` CLI payloads can be richer than Google OAuth and IDE payloads.
`RetrieveUserQuotaSummary` exposes the same two groups shown by Antigravity's Model Quota UI:

- `Gemini Models`: weekly limit and five-hour limit.
- `Claude and GPT models`: weekly limit and five-hour limit.

Older local payloads may only include raw Claude, GPT-OSS, Gemini tiers, account plan, and session reset timestamps.
Current Antigravity IDE local endpoints return `GetUserStatus`, `GetAvailableModels`, and `GetCascadeModelConfigData`
with five-hour/session reset data, but not the app/CLI `RetrieveUserQuotaSummary` weekly/session grouping. OAuth
payloads can be less complete and may only prove model availability. Treat `auto` as the authoritative user-facing mode:
it accepts the first account-matching source in Antigravity app -> `agy` CLI -> Antigravity IDE order, and adds OAuth
when CodexBar has a selected/injected Google account or an existing shared credentials file. An all-100%
`fetchAvailableModels` payload is only accepted after `retrieveUserQuota` echoes bucket fractions; this can be an
availability-style fallback rather than the full Antigravity quota summary.
When OAuth identifies the account but quota endpoints deny access, CodexBar shows `Limits not available` instead of an
empty quota card.

## OAuth account switching

- Login still uses Antigravity's Google OAuth client, discovered from `Antigravity.app` or overridden with `ANTIGRAVITY_OAUTH_CLIENT_ID` and `ANTIGRAVITY_OAUTH_CLIENT_SECRET`.
- A successful login writes the latest shared credentials to `~/.codexbar/antigravity/oauth_creds.json` and upserts a token-account entry for the Google account.
- Each token-account entry stores serialized `AntigravityOAuthCredentials` and is injected into remote fetches through `ANTIGRAVITY_OAUTH_CREDENTIALS_JSON`.
- When a token account is selected, the OAuth fetcher uses that account before falling back to the shared credentials file.
  In `auto` mode the ambient Antigravity app, `agy` CLI, and IDE probes still run first, but a snapshot whose account
  does not match the selected account is rejected so the pipeline falls through to the account-scoped OAuth fetch (see
  `AntigravitySelectedAccountGuard`). If no account is selected/injected, `auto` includes OAuth only when the legacy
  shared credentials file already exists. Explicit `cli`/`oauth` source modes stay authoritative and are not re-checked.
- Removing the last saved token account that matches `~/.codexbar/antigravity/oauth_creds.json` deletes that shared file,
  so a removed CodexBar account does not silently continue refreshing through the legacy shared cache.
- The menu action is labeled `Add Account...`; switching between saved accounts scopes Google OAuth fetches.

## Remote OAuth data sources

- `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
- `POST https://cloudcode-pa.googleapis.com/v1internal:onboardUser`
- `POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` (available, but current observed OAuth
  responses are model-bucket shaped rather than Antigravity 2.0's two quota groups)

## Data sources + fallback order

### 1) Antigravity app local probe

When the Antigravity 2.0 app is running:

1. **Process detection**
   - Command: `ps -ax -o pid=,command=`.
   - The app local strategy scopes detection to the **Antigravity app** language server only
     (`AntigravityStatusProbe(processScope: .appOnly)`). It deliberately does **not**
     attach to an IDE or `agy` CLI process: a lower-information IDE payload should not mask
     `agy`'s richer quota summary, and a stale or still-initializing `agy` can accept the
     connection before it is ready. `agy` is owned exclusively by the CLI HTTPS source below,
     which waits for real API readiness. The probe still classifies all kinds
     (`processInfo(scope: .ideAndCLI)` is used by `isRunning()` for status reporting):
     - the **Antigravity app** language server: process names such as `language_server`, `language_server_macos`,
       `language_server_macos_arm`, or `language-server` plus
       Antigravity markers (`--app_data_dir antigravity`, an Antigravity app bundle path,
       or a path containing `/antigravity/`); or
     - the **IDE** language server: the Antigravity IDE extension language server, usually under
       `Antigravity IDE.app/.../extensions/antigravity/bin/` with `--app_data_dir antigravity-ide`; or
     - the **CLI**: an `antigravity-cli` / `antigravity_cli` path segment, or the
       `agy` binary (path-anchored so unrelated arguments/binaries do not match).
   - CodexBar collects all valid local app language-server candidates and probes each reachable one. If multiple
     app processes are open, it prefers the richer quota-summary snapshot over the legacy `GetUserStatus`
     two-pool fallback.
   - Extract CLI flags:
     - `--csrf_token <token>`. Requirement depends on the match kind:
       - **App/IDE** matches still require it - a tokenless desktop language-server match is
         skipped so a later valid server can be found, otherwise `missingCSRFToken`
         is reported (unchanged behavior).
       - **CLI** matches accept an empty token, because the CLI's language server
         exposes no `--csrf_token` flag and requires none.
     - `--extension_server_port <port>` (HTTP fallback; app/IDE only).
     - `--extension_server_csrf_token <token>` (preferred HTTP fallback token when present).

2. **Port discovery**
   - Command: `lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>`.
   - All listening ports are probed.

3. **Connect port probe (HTTPS)**
   - `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetUnleashData`
   - Headers:
     - `X-Codeium-Csrf-Token: <token>`
     - `Connect-Protocol-Version: 1`
   - First 200 OK response selects the connect port.

4. **Quota fetch**
   - Primary:
     - `POST https://127.0.0.1:<connectPort>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`
   - Fallback 1:
     - `POST https://127.0.0.1:<connectPort>/exa.language_server_pb.LanguageServerService/GetUserStatus`
   - Fallback 2:
     - `POST https://127.0.0.1:<connectPort>/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs`
   - If HTTPS fails, retry over HTTP on `extension_server_port`.

### 2) `agy` CLI HTTPS source

When source mode is `auto` or `cli` and the desktop local probe fails, CodexBar resolves `agy` via:

- `ANTIGRAVITY_CLI_PATH`
- `PATH` / login-shell path lookup
- Well-known paths:
  - `~/.local/bin/agy`
  - `/opt/homebrew/bin/agy`
  - `/usr/local/bin/agy`

CodexBar launches `agy` in a PTY because the CLI exposes its quota server only while the interactive process is alive.
The implementation still does **not** scrape terminal output; it only keeps the process alive, drains discarded PTY
rendering, discovers listening ports with `lsof`, and probes the local HTTPS server:

- First: `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`
- Fallback 1: `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetUserStatus`
- Fallback 2: `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs`

The fallback can return quota without the account email or plan fields from `GetUserStatus`.

Differences from the desktop local probe:

- The CLI HTTPS endpoint does **not** require `X-Codeium-Csrf-Token`.
- Before a one-shot CLI invocation launches `agy`, CodexBar spends at most two seconds looking for an already-running,
  same-user `agy` at the selected binary path and reuses its tokenless local HTTPS endpoint when it returns parseable
  usage for the selected account. Long-lived app/server refreshes keep using CodexBar's managed session, and
  CodexBar-owned pids are excluded from external reuse so probe/idle lifecycle accounting stays balanced.
- Readiness is endpoint-based: CodexBar retries until one of the quota endpoints parses, because fresh `agy`
  processes can bind a port before the quota service is initialized.
- App runtime uses a bounded warm session: `agy` is kept alive briefly after a refresh, then stopped on idle. CLI runtime
  tears it down immediately after the one-shot fetch.
- Repeated endpoint failures force a relaunch instead of reusing a wedged process forever.
- CodexBar records the launched pid + executable identity and conservatively reaps only its own matching stale `agy`
  process on the next launch. It never blind-kills a user-launched `agy`.

### 3) Antigravity IDE local probe

When the Antigravity 2.0 app and `agy` CLI are unavailable, CodexBar probes Antigravity IDE language servers with
`AntigravityStatusProbe(processScope: .ideOnly)`. Current observed IDE payloads return model-level/session quota data
through `GetUserStatus`, `GetAvailableModels`, and `GetCascadeModelConfigData`; `RetrieveUserQuotaSummary` returns 404
from the IDE local server. This means the IDE fallback can show session bars, but should not be expected to provide the
weekly limit shown by Antigravity 2.0.

### 4) OAuth remote fallback

When source mode is `auto`, OAuth is used after app, `agy` CLI, and IDE paths fail if CodexBar has a selected/injected
Google account or an existing shared credentials file. The app, `agy` CLI, and IDE probes still run first, but in
`auto` mode their snapshots are accepted only when the reported account matches the selected account; otherwise the
pipeline falls through to this account-scoped OAuth fetch. When source mode is `oauth`, only OAuth is used and the
shared OAuth file can still be used as a fallback credential source.

## Request body (summary)
- Minimal metadata payload:
  - `ideName: antigravity`
  - `extensionName: antigravity`
  - `locale: en`
  - `ideVersion: unknown`

## Parsing and model mapping
- Preferred source fields:
  - `response.groups[].displayName`
  - `response.groups[].buckets[].bucketId`
  - `response.groups[].buckets[].displayName`
  - `response.groups[].buckets[].remaining.remainingFraction`
  - `response.groups[].buckets[].description`
- Legacy source fields:
  - `userStatus.cascadeModelConfigData.clientModelConfigs[].quotaInfo.remainingFraction`
  - `userStatus.cascadeModelConfigData.clientModelConfigs[].quotaInfo.resetTime`
- Preferred quota summary UI:
  - Render `Gemini Session`, `Gemini Weekly`, `Claude + GPT Session`, and `Claude + GPT Weekly` as named windows.
  - Keep Antigravity's bucket description as reset prose; infer `windowMinutes` from the bucket ID/display name.
  - Use the most constrained known bucket as the compact/menu-bar metric.
- Legacy user-facing quota groups:
  - `Gemini` groups Gemini Pro and Gemini Flash text models.
  - `Claude + GPT` groups Claude text models and GPT/GPT-OSS text models.
- Representative selection:
  - Hidden model rows such as Lite, autocomplete, and image variants do not drive summary bars.
  - For each group, CodexBar uses the lowest remaining known quota row and preserves that row's reset metadata.
  - Rows with reset metadata but no remaining fraction stay visible as unavailable reset context only when their group
    has no known usage row.
- `resetTime` parsing:
  - ISO-8601 preferred; numeric epoch seconds as fallback.
- Identity:
  - `accountEmail` and `planName` only from `GetUserStatus`.

## UI mapping
- Provider metadata:
  - Display: `Antigravity`
  - Labels: `Gemini` (primary), `Claude + GPT` (secondary)
- Status badge: Google Workspace incidents for the Gemini product.
- Antigravity exposes many model rows, but current local payloads show them collapsing into two real usage pools:
  Gemini and Claude/GPT. Detailed usage should not list every raw Gemini tier unless a future source exposes a genuinely
  distinct unknown or consumed quota window.
- Some Antigravity local/CLI model config entries include reset metadata but omit `remainingFraction`. Those windows stay
  in `extraRateWindows` for reset context and are marked with `usageKnown: false`; clients should not render their
  `usedPercent` as a real exhausted quota.

## Constraints
- Internal protocol; fields may change.
- Requires `lsof` for local/CLI port detection.
- Local HTTPS uses a self-signed cert; the probe allows insecure TLS only for loopback hosts.

## Key files
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityCLISession.swift`
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityStatusProbe.swift`
- `Sources/CodexBar/Providers/Antigravity/AntigravityProviderImplementation.swift`
