---
summary: "firmware.ai provider data sources: API token in config/env and quota API response parsing."
read_when:
  - Debugging firmware.ai token storage or quota parsing
  - Updating firmware.ai API endpoints
---

# z.ai provider

z.ai is API-token based. No browser cookies.

## Token sources (fallback order)
1) Config token (`~/.codexbar/config.json` → `providers[].apiKey`).
2) Environment variable `FIRMWARE_API_KEY`.

### Config location
- `~/.codexbar/config.json`

## API endpoint
- `GET https://app.firmware.ai/api/v1/quota`
- Headers:
  - `authorization: Bearer <token>`
  - `accept: application/json`

## Parsing + mapping
- Response fields:
  - `used` → percentage of quota used in current window as a decimal from 0-1.
  - `reset` → timestamp for next reset.
- Reset:
  - `nextResetTime` (ISO8601 timestamp).
  
## Key files
- `Sources/CodexBarCore/Providers/Firmware/FirmwareUsageStats.swift`
- `Sources/CodexBarCore/Providers/Firmware/FirmwareSettingsReader.swift`
