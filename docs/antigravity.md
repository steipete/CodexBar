---
summary: "Antigravity provider notes: OAuth usage, multi-account switching, local LSP probing, and quota parsing."
read_when:
  - Adding or modifying the Antigravity provider
  - Debugging Antigravity port detection or quota parsing
  - Adjusting Antigravity menu labels or model mapping
  - Working with Antigravity OAuth or account switching
---

# Antigravity provider

Antigravity supports three usage data sources:

1. The desktop app's local `language_server` (preferred when the IDE/desktop app is open).
2. The `agy` CLI's embedded HTTPS localhost server (used when the desktop app is closed).
3. Google OAuth-backed remote usage (final fallback, and the source used for multi-account switching). The OAuth path can store multiple Google accounts through the shared token-account switcher.

The local and CLI paths both prefer Antigravity's internal `GetUserStatus` quota payload and may fall back to
`GetCommandModelConfigs`; CodexBar never scrapes the desktop UI or the `agy` TUI.

## OAuth account switching

- Login still uses Antigravity's Google OAuth client, discovered from `Antigravity.app` or overridden with `ANTIGRAVITY_OAUTH_CLIENT_ID` and `ANTIGRAVITY_OAUTH_CLIENT_SECRET`.
- A successful login writes the latest shared credentials to `~/.codexbar/antigravity/oauth_creds.json` and upserts a token-account entry for the Google account.
- Each token-account entry stores serialized `AntigravityOAuthCredentials` and is injected into remote fetches through `ANTIGRAVITY_OAUTH_CREDENTIALS_JSON`.
- When a token account is selected, the OAuth fetcher uses that account before falling back to the shared credentials file.
  In `auto` mode the ambient local desktop and `agy` CLI probes still run first, but a snapshot whose account does not
  match the selected account is rejected so the pipeline falls through to the account-scoped OAuth fetch (see
  `AntigravitySelectedAccountGuard`). Explicit `cli`/`oauth` source modes stay authoritative and are not re-checked.
- The menu action is labeled `Add Account...`; switching between saved accounts scopes Google OAuth fetches.

## Remote OAuth data sources

- `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
- `POST https://cloudcode-pa.googleapis.com/v1internal:onboardUser`
- `POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`

## Data sources + fallback order

### 1) Desktop local probe

When the Antigravity desktop app is running:

1. **Process detection**
   - Command: `ps -ax -o pid=,command=`.
   - The desktop local strategy scopes detection to **IDE** language servers only
     (`AntigravityStatusProbe(processScope: .ideOnly)`). It deliberately does **not**
     attach to an `agy` CLI process: a stale or still-initializing `agy` accepts the
     connection but returns transient `GetUserStatus` errors, which would burn the
     probe timeout. `agy` is owned exclusively by the CLI HTTPS source below, which
     waits for real API readiness. The probe still classifies both kinds
     (`processInfo(scope: .ideAndCLI)` is used by `isRunning()` for status reporting):
     - the **IDE** language server: process name `language_server_macos` plus Antigravity
       markers (`--app_data_dir antigravity` OR path contains `/antigravity/`); or
     - the **CLI**: an `antigravity-cli` / `antigravity_cli` path segment, or the
       `agy` binary (path-anchored so unrelated arguments/binaries do not match).
   - Extract CLI flags:
     - `--csrf_token <token>`. Requirement depends on the match kind:
       - **IDE** matches still require it — a tokenless IDE `language_server` match is
         skipped so a later valid IDE server can be found, otherwise `missingCSRFToken`
         is reported (unchanged behavior).
       - **CLI** matches accept an empty token, because the CLI's language server
         exposes no `--csrf_token` flag and requires none.
     - `--extension_server_port <port>` (HTTP fallback; IDE only).
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
     - `POST https://127.0.0.1:<connectPort>/exa.language_server_pb.LanguageServerService/GetUserStatus`
   - Fallback:
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

- First: `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetUserStatus`
- Fallback: `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs`

The fallback can return quota without the account email or plan fields from `GetUserStatus`.

Differences from the desktop local probe:

- The CLI HTTPS endpoint does **not** require `X-Codeium-Csrf-Token`.
- Readiness is endpoint-based: CodexBar retries until one of the quota endpoints parses, because fresh `agy`
  processes can bind a port before the quota service is initialized.
- App runtime uses a bounded warm session: `agy` is kept alive briefly after a refresh, then stopped on idle. CLI runtime
  tears it down immediately after the one-shot fetch.
- Repeated endpoint failures force a relaunch instead of reusing a wedged process forever.
- CodexBar records the launched pid + executable identity and conservatively reaps only its own matching stale `agy`
  process on the next launch. It never blind-kills a user-launched `agy`.

### 3) OAuth remote fallback

When source mode is `auto`, OAuth is used after both local paths fail. A selected saved Google account scopes the OAuth
fallback. The local and `agy` CLI probes still run first, but in `auto` mode their snapshots are accepted only when the
reported account matches the selected account; otherwise the pipeline falls through to this account-scoped OAuth fetch.
When source mode is `oauth`, only OAuth is used.

## Request body (summary)
- Minimal metadata payload:
  - `ideName: antigravity`
  - `extensionName: antigravity`
  - `locale: en`
  - `ideVersion: unknown`

## Parsing and model mapping
- Source fields:
  - `userStatus.cascadeModelConfigData.clientModelConfigs[].quotaInfo.remainingFraction`
  - `userStatus.cascadeModelConfigData.clientModelConfigs[].quotaInfo.resetTime`
- Mapping priority:
  1) Claude family (thinking variants participate in the normal Claude representative selection)
  2) Gemini Pro Low
  3) Gemini Flash
  4) Fallback: lowest remaining percent
- `resetTime` parsing:
  - ISO-8601 preferred; numeric epoch seconds as fallback.
- Identity:
  - `accountEmail` and `planName` only from `GetUserStatus`.

## UI mapping
- Provider metadata:
  - Display: `Antigravity`
  - Labels: `Claude` (primary), `Gemini Pro` (secondary), `Gemini Flash` (tertiary)
- Status badge: Google Workspace incidents for the Gemini product.
- Antigravity has independent Claude, Gemini Pro, Gemini Flash, and additional model-specific quota windows such as
  GPT-OSS. In automatic menu-bar/highest-usage selection, CodexBar treats the provider as exhausted only when the
  displayed Claude/Gemini summary lanes are exhausted; additional model windows remain visible in detailed usage
  breakdowns.
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
