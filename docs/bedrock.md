---
summary: "AWS Bedrock provider: IAM credentials, Cost Explorer API, budget tracking, and cost history."
read_when:
  - Debugging Bedrock auth or cost fetch
  - Updating Bedrock credential resolution or API calls
---

# AWS Bedrock provider

AWS Bedrock is API-token based using IAM credentials. No browser cookies or OAuth.

## Credential sources (fallback order)

Each credential field is resolved independently, allowing mixed configuration
(e.g. access key from environment, secret from Settings):

1) **Settings UI** (Preferences -> Providers -> AWS Bedrock):
   - Access key ID, Secret access key, Region.
   - Stored in `~/.codexbar/config.json` -> `providers[]` (apiKey, cookieHeader, region).
2) **Environment variables**:
   - `AWS_ACCESS_KEY_ID` (required)
   - `AWS_SECRET_ACCESS_KEY` (required)
   - `AWS_SESSION_TOKEN` (optional, for temporary credentials)
   - `AWS_REGION` or `AWS_DEFAULT_REGION` (defaults to `us-east-1`)
   - `CODEXBAR_BEDROCK_BUDGET` (optional monthly budget in USD)

Settings overrides are merged into the environment per-field by
`ProviderConfigEnvironment.applyAPIKeyOverride`, so a field set in Settings
wins over the same field in the shell environment.

## API endpoints

### Usage (monthly spend)
- AWS Cost Explorer `GetCostAndUsage` (always routed to `us-east-1`).
- Groups by SERVICE dimension, filters client-side for services containing "Bedrock".
- Returns current-month unblended cost in USD.

### Cost history (30-day chart)
- Same Cost Explorer API with DAILY granularity over the last 30 days.
- Produces `CostUsageDailyReport.Entry` items with per-service breakdowns.

Override the Cost Explorer endpoint via `CODEXBAR_BEDROCK_API_URL`.

## Display

- **Primary meter**: Budget usage percentage (only shown when `CODEXBAR_BEDROCK_BUDGET` is set).
- **Identity line**: Monthly spend, budget (if set), and total tokens (if available).
- **Cost history**: 30-day daily cost chart in the token/cost submenu.

## CLI usage

```bash
codexbar --provider bedrock
codexbar -p aws-bedrock  # alias
```

## Environment variables

| Variable | Description |
|----------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS access key ID (required) |
| `AWS_SECRET_ACCESS_KEY` | AWS secret access key (required) |
| `AWS_SESSION_TOKEN` | Session token for temporary credentials (optional) |
| `AWS_REGION` | AWS region (optional, default `us-east-1`) |
| `AWS_DEFAULT_REGION` | Fallback region variable (optional) |
| `CODEXBAR_BEDROCK_BUDGET` | Monthly budget in USD for the progress meter (optional) |
| `CODEXBAR_BEDROCK_API_URL` | Override the Cost Explorer API endpoint (optional) |

## Request signing

All AWS requests are signed with Signature Version 4 using `BedrockAWSSigner`.
Cost Explorer calls always target `us-east-1` regardless of the configured region.

## Key files

- Descriptor: `Sources/CodexBarCore/Providers/Bedrock/BedrockProviderDescriptor.swift`
- Settings reader: `Sources/CodexBarCore/Providers/Bedrock/BedrockSettingsReader.swift`
- Usage fetcher: `Sources/CodexBarCore/Providers/Bedrock/BedrockUsageStats.swift`
- AWS signer: `Sources/CodexBarCore/Providers/Bedrock/BedrockAWSSigner.swift`
- Settings UI: `Sources/CodexBar/Providers/Bedrock/BedrockProviderImplementation.swift`
- Settings store: `Sources/CodexBar/Providers/Bedrock/BedrockSettingsStore.swift`
- Cost history: `Sources/CodexBarCore/CostUsageFetcher.swift` (Bedrock path)
- Config environment: `Sources/CodexBarCore/Config/ProviderConfigEnvironment.swift` (Bedrock overrides)
