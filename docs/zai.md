---
summary: "z.ai / GLM provider data sources, regions, and Coding Plan quota mapping."
read_when:
  - Debugging z.ai token storage or quota parsing
  - Updating z.ai API endpoints
---

# z.ai / GLM provider

z.ai and China-mainland GLM Coding Plan are API-token based. No browser cookies.

## Token sources (fallback order)
1. Config token (`~/.config/codexbar/config.json` or legacy `~/.codexbar/config.json` → `providers[].apiKey`).
2. `Z_AI_API_KEY` for the explicitly selected region.
3. China region only: `BIGMODEL_API_KEY`, `ZHIPU_API_KEY`, `ZHIPUAI_API_KEY`, or `GLM_API_KEY`.
4. China region only, first readable one-line file:
   - `~/.coding-relay/glm-api-key`
   - `~/.config/bigmodel/api_key`
   - `~/.config/zhipu/api_key`

BigModel aliases and relay files are never considered for the Global `api.z.ai` route.

### Config location
- New installs: `~/.config/codexbar/config.json`
- Legacy installs: `~/.codexbar/config.json`
- Override for scripts/tests: `CODEXBAR_CONFIG=/path/to/config.json`

## Setup

Set **API region** to **Global (api.z.ai)** or **BigModel CN (open.bigmodel.cn)**.

- UI: Settings → Providers → z.ai. For team usage, add a token account, turn on **Team mode**, then enter the API key,
  Organization ID, and Project ID.
- CLI personal:

  ```bash
  printf '%s' "$Z_AI_API_KEY" | codexbar config set-api-key --provider zai --stdin
  ```

- CLI team:

  ```bash
  printf '%s' "$Z_AI_API_KEY" | codexbar config set-api-key --provider zai --stdin \
    --label Team \
    --usage-scope team \
    --organization-id org_... \
    --workspace-id proj_...
  ```

- Check:

  ```bash
  codexbar config validate
  codexbar usage --provider zai --account Team
  ```

Personal config can use `providers[].apiKey`. Team config uses `tokenAccounts`:

```json
{
  "id": "zai",
  "enabled": true,
  "region": "bigmodel-cn",
  "tokenAccounts": {
    "version": 1,
    "activeIndex": 0,
    "accounts": [
      {
        "id": "00000000-0000-0000-0000-000000000001",
        "label": "Team",
        "token": "<z.ai API key>",
        "addedAt": 0,
        "lastUsed": null,
        "usageScope": "team",
        "organizationId": "org_...",
        "workspaceID": "proj_..."
      }
    ]
  }
}
```

Keep `organizationId` and `workspaceID` single-line. Do not paste display names, URLs, or multiple IDs.

## Finding the BigModel team IDs
For BigModel China team usage, CodexBar needs the `Bigmodel-Organization` and `Bigmodel-Project` request headers:

1. Open the BigModel API-key page and create/copy the API key:
   - `https://bigmodel.cn/usercenter/proj-mgmt/apikeys`
   - Some accounts still redirect through `https://open.bigmodel.cn/usercenter/apikeys`.
2. Open the team usage dashboard:
   - `https://bigmodel.cn/coding-plan/team/usage-stats`
3. Select the organization/team and project to track.
4. Open browser DevTools → Network, refresh the team usage page, and inspect the
   request to `api/monitor/usage/quota/limit` or `api/monitor/usage/model-usage`. Copy these request headers:
   - `Bigmodel-Organization` → `organizationId`
   - `Bigmodel-Project` → `workspaceID`

Copy each value once, on one line. Multi-line or duplicated IDs can make the API return `data: {}`, leaving MCP,
5-hour, and hourly usage empty.

## API endpoint
- `GET https://api.z.ai/api/monitor/usage/quota/limit`
- BigModel (China mainland) host: `https://open.bigmodel.cn`
- Override host via Providers → z.ai → *API region* or `Z_AI_API_HOST=open.bigmodel.cn`.
- Override the full quota URL (e.g. coding plan endpoint) via `Z_AI_QUOTA_URL=https://open.bigmodel.cn/api/coding/paas/v4`.
- Endpoint overrides must be explicit HTTPS URLs or bare hosts/paths that CodexBar normalizes to HTTPS. Explicit
  `http://` overrides fail closed before the bearer token is attached to a request. If both z.ai overrides are set,
  `Z_AI_QUOTA_URL` has priority for quota requests; a stale lower-priority `Z_AI_API_HOST` is ignored for that quota
  path, but direct model-usage requests still validate `Z_AI_API_HOST` before sending bearer auth.
- Canonical overrides are region-checked before bearer auth: `api.z.ai` cannot override a BigModel CN selection,
  and `open.bigmodel.cn` cannot override a Global selection. Custom HTTPS proxy hosts remain explicit overrides.
- Headers:
  - `authorization: Bearer <token>`
  - `accept: application/json`

### BigModel team usage
- The default usage scope is **personal**. Only a token account with `usageScope: team` is queried as team usage.
- Each z.ai token account can enable **Team mode** via UI, CLI, or config. Team accounts store:
  - `usageScope`: `team`
  - `organizationId`: BigModel organization id
  - `workspaceID`: BigModel project id
- Team quota scope appends `type=2`; team hourly model usage appends `type=3`. Both send the BigModel selectors:
  - `Bigmodel-Organization: <org id>`
  - `Bigmodel-Project: <project id>`
- Live API checks return success with empty limits when one of the selectors is missing, so CodexBar treats both
  Organization ID and Project ID as required for team usage.

## Usage dashboard
- Global: `https://z.ai/manage-apikey/coding-plan/personal/my-plan`
- BigModel China: `https://bigmodel.cn/coding-plan/personal/usage`
- BigModel China team: `https://bigmodel.cn/coding-plan/team/usage-stats`
- CodexBar's Usage Dashboard action follows the configured API region.

## Parsing + mapping
- Response fields:
  - `data.limits[]` → each limit entry.
  - `data.planName` (or `plan`, `plan_type`, `packageName`, `level`) → plan label.
- Limit types:
  - Both `TOKENS_LIMIT` and `CREDIT_LIMIT` supply Coding Plan windows.
  - A single Coding Plan limit becomes primary. With multiple limits, the first becomes primary and the last becomes secondary after sorting by duration; unknown durations sort last.
  - `TIME_LIMIT` → a separate MCP lane when a Coding Plan window is available, otherwise the primary MCP window; never a fabricated monthly Coding Plan window.
- Usage percentage:
  - An integer `percentage` is required. When a positive `usage` limit and a `currentValue` or `remaining` count are present, the counts determine the used percentage. The result is clamped to 0–100%.
- Window duration:
  - Unit + number → minutes/hours/days.
- Reset:
  - `nextResetTime` (epoch ms) → date.
- Usage details:
  - `usageDetails[]` per model (MCP usage list).

## Key files
- `Sources/CodexBarCore/Resources/Plugins/zai.js` (quota parsing and window mapping)
- `Sources/CodexBarCore/Providers/Zai/ZaiProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Zai/ZaiSettingsReader.swift`
- `Sources/CodexBar/ZaiTokenStore.swift` (legacy migration helper)
- `Tests/CodexBarTests/ProviderPluginDetailsParityTests.swift` (quota fixtures, including credit limits)
