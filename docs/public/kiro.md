---
summary: "Kiro provider data sources: CLI-based usage via kiro-cli /usage command."
read_when:
  - Debugging Kiro usage parsing
  - Updating kiro-cli command behavior
  - Reviewing Kiro credit window mapping
---

# Kiro provider

Kiro uses the AWS `kiro-cli` tool to fetch usage data. No browser cookies or OAuth flow—authentication is handled by AWS Builder ID through the CLI.

## Data sources

1) **CLI command** (primary and only strategy)
   - Command: `kiro-cli chat --no-interactive "/usage"`
   - Timeout: 10 seconds.
   - Requires `kiro-cli` installed and logged in via AWS Builder ID.
   - Output is ANSI-decorated; CodexBar strips escape sequences before parsing.

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

- **Primary window**: Monthly credits percentage (bar meter).
  - `usedPercent`: extracted from `███...█ X%` pattern.
  - `resetsAt`: parsed from `resets on MM/DD` (assumes current or next year).
- **Secondary window**: Bonus credits (when present).
  - Parsed from `Bonus credits: X.XX/Y credits used`.
  - Expiry from `expires in N days`.
- **Identity**:
  - `accountOrganization`: plan name (e.g., "KIRO FREE").
  - `loginMethod`: plan name (used for menu display).

## Status

Kiro does not have a dedicated status page. The "View Status" link opens the AWS Health Dashboard:
- `https://health.aws.amazon.com/health/status`

## Key files

- `Sources/CodexBarCore/Providers/Kiro/KiroProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Kiro/KiroStatusProbe.swift`
- `Sources/CodexBar/Providers/Kiro/KiroProviderImplementation.swift`
