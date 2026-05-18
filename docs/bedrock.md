---
summary: "AWS Bedrock provider: Cost Explorer credentials, budget tracking, and usage display."
read_when:
  - Setting up AWS Bedrock usage tracking
  - Debugging Bedrock Cost Explorer fetches
  - Updating Bedrock credentials, region, or budget handling
---

# AWS Bedrock provider

CodexBar reads AWS Cost Explorer for Bedrock spend and can compare the current month against an optional budget.

## Setup

Provide AWS credentials through the environment inherited by CodexBar or the CLI:

```bash
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_REGION="us-east-1"
```

Optional:

```bash
export AWS_SESSION_TOKEN="..."
export CODEXBAR_BEDROCK_BUDGET="250"
```

The AWS identity must have permission to call Cost Explorer APIs, including `ce:GetCostAndUsage`.

## Data source

- Service: AWS Cost Explorer.
- Region: `AWS_REGION` or `AWS_DEFAULT_REGION`, defaulting to `us-east-1`.
- Usage: current-month Bedrock spend and historical daily cost buckets.
- Budget: `CODEXBAR_BEDROCK_BUDGET`, when set to a positive dollar amount.
- Test override: `CODEXBAR_BEDROCK_API_URL` replaces the Cost Explorer endpoint.

## Display

- Shows month-to-date Bedrock spend.
- Shows budget progress when a budget is configured.
- Reuses the shared inline dashboard for daily cost history when enough buckets are available.

## CLI

```bash
codexbar --provider bedrock --source api
codexbar --provider bedrock --format json --pretty
```

## Troubleshooting

### "No AWS Bedrock cost data available"

- Confirm the credentials are visible to CodexBar.
- Confirm the AWS account has Cost Explorer enabled.
- Confirm the IAM principal can call `ce:GetCostAndUsage`.
- If using temporary credentials, include `AWS_SESSION_TOKEN`.

### Wrong region

Set `AWS_REGION` or `AWS_DEFAULT_REGION`. Bedrock usage is regional, but Cost Explorer itself is account-level; CodexBar still needs a signing region for the request.

## Key files

- `Sources/CodexBarCore/Providers/Bedrock/BedrockProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Bedrock/BedrockSettingsReader.swift`
- `Sources/CodexBarCore/Providers/Bedrock/BedrockUsageStats.swift`
- `Sources/CodexBarCore/Providers/Bedrock/BedrockAWSSigner.swift`
