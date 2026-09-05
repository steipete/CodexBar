---
summary: "Kiro provider data sources: CLI-based usage via kiro-cli /usage, enriched with GetUsageLimits for overage."
read_when:
  - Debugging Kiro usage parsing
  - Updating kiro-cli command behavior
  - Reviewing Kiro credit window mapping
  - Working on Kiro overage credits
---

# Kiro provider

Kiro uses the AWS `kiro-cli` tool to fetch usage data. No browser cookies or OAuth flow—authentication is handled by AWS Builder ID through the CLI.

## Data sources

1) **CLI command** (primary)
   - Command: `kiro-cli chat --no-interactive "/usage"`
   - Timeout: 20 seconds (idle cutoff after 4 seconds of no output once the CLI starts responding).
   - CodexBar tries ordinary stdout/stderr pipes first for current Kiro CLI releases. Incomplete or unusable
     pipe output falls back to a pseudo-terminal within the same overall command deadline for older releases.
   - Requires `kiro-cli` installed and logged in via AWS Builder ID.
   - Output is ANSI-decorated; CodexBar strips escape sequences before parsing.

2) **`GetUsageLimits` API** (overage enrichment, best effort)
   - The CLI report states credits against the plan alone and **omits the overage section entirely for
     organization accounts**, so it can never state the overage cap. The API carries the overage allowance
     on top of the plan, which is the ceiling an account actually spends against.
   - Endpoint: `POST https://codewhisperer.us-east-1.amazonaws.com/`,
     header `X-Amz-Target: AmazonCodeWhispererService.GetUsageLimits`, body `{"profileArn": ...}`.
   - Credentials come from the CLI's own state, opened **read-only** (the CLI owns the token and its refresh):
     `~/Library/Application Support/kiro-cli/data.sqlite3`
     - `auth_kv` key `kirocli:odic:token` → `access_token`
     - `state` key `api.codewhisperer.profile` → `arn`
   - Runs after the CLI probe, so a token the CLI refreshed along the way is already in place.
   - Failure is non-fatal: the plan-relative numbers the CLI produced stand. The API path depends on the CLI's
     private token store, which a Kiro release can move, whereas the CLI reads only its own published output.

## Output format (example)

```
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃                                                          | KIRO FREE      ┃
┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫
┃ Monthly credits:                                                          ┃
┃ ████████████████████████████████████████████████████████ 100% (resets on 01/01) ┃
┃                              (0.00 of 50 covered in plan)                 ┃
┃ Bonus credits:                                                            ┃
┃ 0.00/100 credits used, expires in 88 days                                 ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
```

## Snapshot mapping

- **Primary window**: Monthly plan credits percentage (bar meter).
  - `usedPercent`: extracted from `███...█ X%` pattern, or `planUsed / planLimit` when the API answered.
  - `resetsAt`: parsed from `resets on MM/DD` (assumes current or next year), or `nextDateReset` from the API.
- **Secondary window**: Bonus credits (when present).
  - Parsed from `Bonus credits: X.XX/Y credits used`. Always CLI-sourced. When `GetUsageLimits` includes a
    non-empty `bonuses[]` array, CodexBar keeps the CLI plan gauge instead of treating bonus spend as plan
    usage; overage enrichment still applies.
  - Expiry from `expires in N days`.
- **Extra window** `kiro-overage`: overage credits spent against `overageCapWithPrecision` (API only). This
  is a second credit ceiling, not optional extra usage — the plan gauge stays plan-only so a spent plan
  still shows remaining overage headroom. The bar reuses the Credits remaining copy
  (`N of M credits left`).
- **Provider cost**: `overageCharges` against `overageCap × overageRate` (API only).
- **Identity**:
  - `accountOrganization`: plan name (e.g., "KIRO FREE").
  - `loginMethod`: plan name (used for menu display).

### Plan vs overage split

`currentUsageWithPrecision` is the **total** including overage, so plan usage is
`currentUsage - currentOverages`. Feeding `currentUsage` into the plan gauge would read over 100% and
double-count the same spend in both gauges. Components are validated individually rather than as a sum, so a
negative one cannot hide inside a positive total.

## Status

Kiro does not have a dedicated status page. The "View Status" link opens the AWS Health Dashboard:
- `https://health.aws.amazon.com/health/status`

## Key files

- `Sources/CodexBarCore/Providers/Kiro/KiroProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Kiro/KiroStatusProbe.swift`
- `Sources/CodexBarCore/Providers/Kiro/KiroUsageLimitsAPI.swift`
- `Sources/CodexBar/Providers/Kiro/KiroProviderImplementation.swift`
