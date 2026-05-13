---
summary: "Antigravity provider notes: OAuth usage, multi-account switching, local LSP probing, and quota parsing."
read_when:
  - Adding or modifying the Antigravity provider
  - Debugging Antigravity port detection or quota parsing
  - Adjusting Antigravity menu labels or model mapping
  - Working with Antigravity OAuth or account switching
---

# Antigravity provider

Antigravity supports local IDE probing and Google OAuth-backed remote usage. The OAuth path can store multiple Google accounts through the shared token-account switcher.

## OAuth account switching

- Login still uses Antigravity's Google OAuth client, discovered from `Antigravity.app` or overridden with `ANTIGRAVITY_OAUTH_CLIENT_ID` and `ANTIGRAVITY_OAUTH_CLIENT_SECRET`.
- A successful login writes the latest shared credentials to `~/.codexbar/antigravity/oauth_creds.json` and upserts a token-account entry for the Google account.
- Each token-account entry stores serialized `AntigravityOAuthCredentials` and is injected into remote fetches through `ANTIGRAVITY_OAUTH_CREDENTIALS_JSON`.
- When a token account is selected, the OAuth fetcher uses that account before falling back to the shared credentials file.
- The menu action is labeled `Add Account...`; switching between saved accounts uses the existing segmented/stacked token-account menu UI.

## Remote OAuth data sources

- `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
- `POST https://cloudcode-pa.googleapis.com/v1internal:onboardUser`
- `POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`

## Local data sources + fallback order

## Data sources + fallback order

1) **Process detection**
   - Command: `ps -ax -o pid=,command=`.
   - Match process name: `language_server_macos` plus Antigravity markers:
     - `--app_data_dir antigravity` OR path contains `/antigravity/`.
   - Extract CLI flags:
     - `--csrf_token <token>` (required).
     - `--extension_server_port <port>` (HTTP fallback).

2) **Port discovery**
   - Command: `lsof -nP -iTCP -sTCP:LISTEN -p <pid>`.
   - All listening ports are probed.

3) **Connect port probe (HTTPS)**
   - `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetUnleashData`
   - Headers:
     - `X-Codeium-Csrf-Token: <token>`
     - `Connect-Protocol-Version: 1`
   - First 200 OK response selects the connect port.

4) **Quota fetch**
   - Primary:
     - `POST https://127.0.0.1:<connectPort>/exa.language_server_pb.LanguageServerService/GetUserStatus`
   - Fallback:
     - `POST https://127.0.0.1:<connectPort>/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs`
   - If HTTPS fails, retry over HTTP on `extension_server_port`.

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
  1) Claude (label contains `claude` but not `thinking`)
  2) Gemini Pro Low (label contains `pro` + `low`)
  3) Gemini Flash (label contains `gemini` + `flash`)
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

## Constraints
- Internal protocol; fields may change.
- Requires `lsof` for port detection.
- Local HTTPS uses a self-signed cert; the probe allows insecure TLS.

## Key files
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityStatusProbe.swift`
- `Sources/CodexBar/Providers/Antigravity/AntigravityProviderImplementation.swift`
