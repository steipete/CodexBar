---
summary: "Antigravity provider notes: local LSP probing, port discovery, quota parsing, and UI mapping."
read_when:
  - Adding or modifying the Antigravity provider
  - Debugging Antigravity port detection or quota parsing
  - Adjusting Antigravity menu labels or model mapping
---

# Antigravity provider

Antigravity is a local-only provider. We talk directly to the Antigravity language server running on the same machine.

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
