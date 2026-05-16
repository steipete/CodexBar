---
summary: "Grok provider data sources: ACP JSON-RPC over `grok agent stdio`, OAuth credentials, and local session signals."
read_when:
  - Debugging Grok billing/usage parsing
  - Updating `grok agent stdio` JSON-RPC integration
  - Adjusting `~/.grok/auth.json` credential reading
---

# Grok provider

Grok uses xAI's official Grok Build CLI (`grok`, released 2026-05-14). Usage data is
fetched via the ACP JSON-RPC `x.ai/billing` extension method over `grok agent stdio`.
No browser cookies, no direct REST calls.

## Data sources + fallback order

1) **`~/.grok/auth.json` (primary; always works for SuperGrok subscribers)**
   - Reads `email`, `team_id`, `first_name`/`last_name`, plan-hint (`auth_mode`)
     for the identity row in the menu.
2) **`grok agent stdio` ACP JSON-RPC** (best-effort, currently disabled in grok 0.1.210)
   - We spawn `grok agent stdio` and call `initialize` + `x.ai/billing` (no params).
   - **Known limitation:** in grok 0.1.210 the `x.ai/billing` extension method
     is only wired in the interactive TUI; the agent-stdio surface returns
     `-32601 Method not found`. The provider degrades silently to identity-only
     when this happens. When xAI exposes billing on the agent protocol, no
     code change is required.
   - One non-obvious quirk: grok's ACP parser does not unescape `\/` in method
     names. `Foundation.JSONSerialization.data` defaults to escaping forward
     slashes, so payloads must be re-encoded with `\/` → `/` before being
     written to stdin or grok will silently drop them (12s client-side
     timeout instead of the expected error response).
3) **Local session signals** (informational fallback)
   - Walks `~/.grok/sessions/<encoded-cwd>/<session-id>/signals.json` files (last 30 days).
   - Aggregates `totalTokensBeforeCompaction`, `contextTokensUsed`, `modelsUsed`,
     and the most recent session timestamp.

## OAuth credentials

- File: `~/.grok/auth.json` (path overridable via `GROK_HOME`).
- Top-level keys are OIDC scope URLs. CodexBar prefers entries under
  `https://auth.x.ai::<client-id>` (SuperGrok), falling back to
  `https://accounts.x.ai/sign-in` (legacy session).
- Required fields per entry: `key` (bearer token), `refresh_token`, `expires_at`,
  `auth_mode`, `email`, `team_id`, `user_id`, `first_name`/`last_name`.
- Tokens are issued by `grok login` and expire after ~7 days; refresh is handled by
  the CLI itself (CodexBar does not refresh; it just reads the cached credential).

## JSON-RPC contract

- Transport: stdin/stdout, newline-delimited JSON-RPC 2.0 (no Content-Length framing).
- `initialize` params:
  ```json
  {
    "protocolVersion": "1",
    "clientCapabilities": {
      "fs": { "readTextFile": false, "writeTextFile": false },
      "terminal": false
    }
  }
  ```
- `x.ai/billing` result shape (all monetary values are `{ val: <cents> }`):
  ```json
  {
    "billingCycle": {
      "billingPeriodStart": "2026-05-01T00:00:00Z",
      "billingPeriodEnd": "2026-06-01T00:00:00Z"
    },
    "monthlyLimit": { "val": 99900 },
    "onDemandCap": { "val": 0 },
    "on_demand_enabled": false,
    "disabledByConfig": false,
    "usage": {
      "includedUsed": { "val": 12345 },
      "onDemandUsed": { "val": 0 },
      "totalUsed": { "val": 12345 }
    }
  }
  ```
- Auth errors surface as JSON-RPC errors with the message
  `"Authentication required to fetch billing data. Run 'grok login' to authenticate."`.
- Timeouts: 8s for `initialize`, 12s for `x.ai/billing`. CodexBar terminates the
  child `grok` process on timeout to avoid leaking subprocesses.

## Mapping to `UsageSnapshot`

- **Primary window** = monthly credit usage:
  - `usedPercent` = `usage.totalUsed.val / monthlyLimit.val * 100`.
  - `resetsAt` = `billingCycle.billingPeriodEnd`.
- **Identity**:
  - `accountEmail` from credential `email`.
  - `accountOrganization` from credential `team_id`.
  - `loginMethod` = "SuperGrok" for OIDC, otherwise the raw `auth_mode`.

## Local fallback (`~/.grok/sessions/`)

Each session directory contains `signals.json` with fields like:

```json
{
  "turnCount": 1,
  "contextTokensUsed": 2968,
  "contextWindowTokens": 512000,
  "totalTokensBeforeCompaction": 0,
  "modelsUsed": ["grok-build"],
  "primaryModelId": "grok-build",
  "sessionDurationSeconds": 47
}
```

CodexBar aggregates these into a `GrokLocalSessionSummary` (session count, total
tokens, last session time, primary model) and exposes it for diagnostics even when
the RPC path is unavailable.

## Status

xAI has not exposed a Statuspage-style status feed yet. The "View Status" link
points to `https://status.x.ai`.

## Key files

- `Sources/CodexBarCore/Providers/Grok/GrokProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Grok/GrokAuth.swift`
- `Sources/CodexBarCore/Providers/Grok/GrokRPCClient.swift`
- `Sources/CodexBarCore/Providers/Grok/GrokStatusProbe.swift`
- `Sources/CodexBarCore/Providers/Grok/GrokLocalSessionScanner.swift`
- `Sources/CodexBar/Providers/Grok/GrokProviderImplementation.swift`
