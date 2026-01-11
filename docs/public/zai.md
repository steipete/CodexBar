---
summary: "z.ai provider data sources: API token in Keychain/env and quota API response parsing."
read_when:
  - Debugging z.ai token storage or quota parsing
  - Updating z.ai API endpoints
---

# z.ai provider

z.ai is API-token based. No browser cookies.

## Token sources (fallback order)
1) Preferences token (stored in Keychain).
2) Environment variable `Z_AI_API_KEY`.

### Keychain location
- Service: `com.steipete.CodexBar`
- Account: `zai-api-token`

## API endpoint
- `GET https://api.z.ai/api/monitor/usage/quota/limit`
- Headers:
  - `authorization: Bearer <token>`
  - `accept: application/json`

## Parsing + mapping
- Response fields:
  - `data.limits[]` → each limit entry.
  - `data.planName` (or `plan`, `plan_type`, `packageName`) → plan label.
- Limit types:
  - `TOKENS_LIMIT` → primary (tokens window).
  - `TIME_LIMIT` → secondary (MCP/time window) if tokens also present.
- Window duration:
  - Unit + number → minutes/hours/days.
- Reset:
  - `nextResetTime` (epoch ms) → date.
- Usage details:
  - `usageDetails[]` per model (MCP usage list).

## Key files
- `Sources/CodexBarCore/Providers/Zai/ZaiUsageStats.swift`
- `Sources/CodexBarCore/Providers/Zai/ZaiSettingsReader.swift`
- `Sources/CodexBar/ZaiTokenStore.swift`
