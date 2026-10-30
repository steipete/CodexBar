---
summary: "Kiro provider data sources: read-only GetUsageLimits with V2 CLI fallback."
read_when:
  - Debugging Kiro usage parsing
  - Updating kiro-cli command behavior
  - Reviewing Kiro credit window mapping
  - Working on Kiro overage credits
---

# Kiro provider

Kiro reuses `kiro-cli` authentication for API usage reads and CLI fallback. The CLI owns authentication; CodexBar does not import browser cookies or implement a separate OAuth flow.

## Data sources

1) **`GetUsageLimits` API** (preferred)
   - A positive plan allowance without unseparated bonus spend supplies credits, resets, and overage
     without starting `/usage` or `/context` chats. Identity still comes only from `kiro-cli whoami`.
     The API does not supply the CLI plan label or context breakdown; these snapshots use the label
     `Kiro` and omit context details.
   - Endpoint follows the CLI profile ARN: US East uses `POST https://codewhisperer.us-east-1.amazonaws.com/`;
     Frankfurt uses `POST https://q.eu-central-1.amazonaws.com/`. Invalid or unsupported profile ARNs skip the API.
     Header `X-Amz-Target: AmazonCodeWhispererService.GetUsageLimits`, body `{"profileArn": ...}`.
   - Credentials come from the CLI's own state, opened **read-only** (the CLI owns the token and its refresh):
     `~/Library/Application Support/kiro-cli/data.sqlite3`
     - `auth_kv` key `kirocli:odic:token` → `access_token`
     - `state` key `api.codewhisperer.profile` → `arn`
   - Regional endpoints follow [AWS profile-region routing](https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/firewall.html), independently of the IAM Identity Center authentication region.
   - This is the existing private CLI service/state contract, not a documented public Kiro API.
     Missing credentials, API failures, nonpositive allowances, or combined bonus totals fall back to the CLI.
     An unavailable API is retried after the CLI attempt, which may refresh its token. Only usable plan
     metrics replace a failed CLI report; otherwise the original error remains. Login failures and cancellation
     are preserved.
   - The API also carries overage allowance and consumption that the CLI omits for organization accounts.
     Ambiguous bonus totals can enrich a successful CLI report's overage data without replacing its plan gauge.

2) **V2 CLI report** (fallback)
   - Command: `kiro-cli chat --no-interactive "/usage" --v2`.
   - Context details use `kiro-cli chat --no-interactive "/context" --v2` on this fallback path only.
   - Kiro CLI V3 can send non-interactive slash commands to the model as prompts (#4853).
     The [CLI command reference](https://kiro.dev/docs/reference/cli-commands/) and
     [V3 rollout announcement](https://kiro.dev/blog/cli-3/) document `--v2` as selecting the V2 harness
     for one invocation without changing saved settings. A CLI explicitly rejecting the flag is retried
     without it for compatibility with older releases.
   - Both fallback commands start chat sessions. `--no-interactive` does not promise session-free execution;
     Kiro CLI 2.33.1 saves empty session pairs for these probes (#4746). API-first refreshes avoid those pairs
     when usable API metrics are available, but CLI fallback can still create them. CodexBar does not delete
     the CLI's session files.
   - Timeout: 20 seconds (idle cutoff after 4 seconds of no output once the CLI starts responding).
     Ordinary stdout/stderr pipes come first; incomplete output falls back to a pseudo-terminal within
     the same command deadline.
   - Requires `kiro-cli` installed and logged in. Output is ANSI-decorated; CodexBar strips escape sequences.
   - Kiro CLI 2.20 summaries such as `Plan: KIRO PRO MAX | 1 usage breakdowns` are accepted as plan-only
     reports. A breakdown count does not imply zero usage or an available allowance.

Background refreshes first make an unauthenticated, four-second `HEAD` request to the CLI profile's usage
host. Missing or unsupported private region state uses the default US East host. A transport failure stops
the refresh before any CLI command starts and preserves last-good usage through shared offline handling.
Any HTTP response establishes reachability. Manual refreshes skip this preflight. `--no-interactive` disables
the chat loop, not browser authentication; the preflight contains offline background sign-in attempts.

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
  - Omitted, along with numeric plan-credit rows, when a managed report or breakdown summary withholds
    metrics and usable API enrichment is unavailable. The plan name remains visible. Bonus-inclusive API
    totals and zero allowances do not replace the CLI plan metrics or invent a missing plan gauge.
  - `usedPercent`: extracted from `███...█ X%` pattern, or `planUsed / planLimit` when the API answered.
  - `resetsAt`: parsed from `resets on MM/DD` (assumes current or next year), or `nextDateReset` from the API.
  - `windowMinutes`: the monthly sentinel when a reset date is known, so the gauge gets calendar-month pace,
    a Plan Usage history series, and the recorded quota burndown.
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
  - `accountEmail`: the CLI-reported account email, when available.
  - `loginMethod`: the CLI-reported authentication method. The plan remains a provider detail row.

### Monthly pace and history

When the monthly credit reset is known, the card shows calendar-month pace alongside the credits bar;
the remaining-credit count stays below it. The menu bar honors the global Pace or Both display mode
while preserving Kiro's Hidden choice. Missing or expired resets do not produce a forecast.

With historical tracking enabled, Plan Usage records monthly plan utilization in the shared local
`history/kiro.json` store. The series key is `monthly:43200`; the duration is resolved from the actual
calendar month for pace and the burndown chart, including February and 31-day months. Bonus and overage
credits stay separate and are not recorded as monthly plan usage. The store coalesces observations by
hour and retains at most 17,520 samples per series (730 days at one sample per hour). Identified accounts
use a hash of the normalized provider/email identity; reports without identity follow the shared
unscoped/last-selected-account behavior. No separate Kiro history setting or storage migration is needed.

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
