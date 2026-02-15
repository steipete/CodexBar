---
summary: "Antigravity provider notes: OAuth credentials, local LSP probing, port discovery, quota parsing, and UI mapping."
read_when:
  - Adding or modifying the Antigravity provider
  - Debugging Antigravity port detection or quota parsing
  - Adjusting Antigravity menu labels or model mapping
  - Working with Antigravity OAuth credentials
---

# Antigravity provider

Antigravity supports OAuth-authorized Cloud Code quota and local language server probing.

## Usage source modes

- **Auto** (default): OAuth/manual first, fallback to local server
- **OAuth**: OAuth/manual only
- **Local**: Antigravity local server only

## OAuth credentials

- **Keychain**: stored from the OAuth browser flow
- **Manual tokens**: stored in token accounts with `manual:` prefix (access `ya29.` + optional refresh `1//`) when Keychain is disabled; otherwise saved to Keychain under the account label.
- **Local import**: `~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb`
  - refresh token: `jetskiStateSync.agentManagerInitState` (base64 protobuf, field 6 contains nested OAuthTokenInfo)
  - access token/email: `antigravityAuthStatus` JSON (`apiKey`, `email`)
  - Import button always visible; storage adapts to Keychain setting (Keychain when enabled, config.json when disabled)
- OAuth callback server listens on `http://127.0.0.1:11451+`

## Cloud Code API endpoints

- `POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
- `POST https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
- `POST https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels` (fallback)
- `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` (fallback for fetchAvailableModels)

## Authorized fetch flow

1. Best-effort `loadCodeAssist` to bootstrap `projectId`
2. `fetchAvailableModels` with `projectId` (primary)
3. `retrieveUserQuota` with `projectId` (fallback if primary returns empty or fails)

## Local server data sources + fallback order

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

### OAuth/Credentials
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityOAuth/AntigravityOAuthCredentials.swift`
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityOAuth/AntigravityTokenRefresher.swift`
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityOAuth/AntigravityLocalImporter.swift`
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityOAuth/antigravity_state.proto` (protobuf definition)
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityOAuth/antigravity_state.pb.swift` (generated Swift)
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityOAuth/AntigravityCloudCodeClient.swift`
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityOAuth/AntigravityOAuthFlow.swift`
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityOAuth/AntigravityAuthorizedFetchStrategy.swift`
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityOAuth/AntigravityUsageSource.swift`

### Local Server
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityStatusProbe.swift`
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityProviderDescriptor.swift`

### App Integration
- `Sources/CodexBar/Providers/Antigravity/AntigravityProviderImplementation.swift`
- `Sources/CodexBar/Providers/Antigravity/AntigravitySettingsStore.swift`
- `Sources/CodexBar/Providers/Antigravity/AntigravityLoginFlow.swift`

### Tests
- `Tests/CodexBarTests/AntigravityOAuthTests.swift`
- `Tests/CodexBarTests/AntigravityStatusProbeTests.swift`
