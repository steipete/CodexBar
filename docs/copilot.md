---
summary: "Copilot provider data sources: GitHub device flow + Copilot internal usage API."
read_when:
  - Debugging Copilot login or usage parsing
  - Updating GitHub OAuth device flow behavior
---

# Copilot provider

Copilot uses GitHub OAuth device flow and the Copilot internal usage API. No browser cookies.

## Data sources + fallback order

1) **GitHub OAuth device flow** (user initiated)
   - Device code request:
     - `POST https://github.com/login/device/code`
   - Token polling:
     - `POST https://github.com/login/oauth/access_token`
   - Optional enterprise host:
     - set Copilot `enterpriseHost` in `~/.codexbar/config.json` or the provider settings UI
     - CodexBar normalizes values such as `https://octocorp.ghe.com/login` to `octocorp.ghe.com`
     - device flow uses `https://<enterpriseHost>/login/...`
   - Scope: `read:user`.
   - Token stored in config:
     - `~/.codexbar/config.json` → `providers[].apiKey` for `copilot`
      - token accounts use `providers[].tokenAccounts`

2) **Usage fetch**
   - `GET https://api.github.com/copilot_internal/user`
   - With an enterprise host, the API host is `api.<enterpriseHost>`.
   - Headers:
     - `Authorization: token <github_oauth_token>`
     - `Accept: application/json`
     - `Editor-Version: vscode/1.96.2`
     - `Editor-Plugin-Version: copilot-chat/0.26.7`
     - `User-Agent: GitHubCopilotChat/0.26.7`
     - `X-Github-Api-Version: 2025-04-01`

## Snapshot mapping
- Primary: `quotaSnapshots.premiumInteractions` percent remaining → used percent.
- Secondary: `quotaSnapshots.chat` percent remaining → used percent.
- Reset dates are not provided by the API.
- Plan label from `copilotPlan`.

## Key files
- `Sources/CodexBarCore/Providers/Copilot/CopilotUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/Copilot/CopilotDeviceFlow.swift`
- `Sources/CodexBar/Providers/Copilot/CopilotLoginFlow.swift`
- `Sources/CodexBar/CopilotTokenStore.swift` (legacy migration helper)
