---
summary: "AWS Bedrock provider: Cost Explorer spend, CloudWatch Claude activity, credentials, and budgets."
read_when:
  - Setting up AWS Bedrock usage tracking
  - Debugging Bedrock Cost Explorer or CloudWatch fetches
  - Updating Bedrock credentials, region, budget, or activity handling
---

# AWS Bedrock provider

CodexBar reads AWS Cost Explorer for Bedrock spend and can compare the current month against an optional budget. When
permitted, it also reads CloudWatch for rolling 14-day Claude token and request totals in the configured region.

## Authentication

CodexBar supports two authentication modes, selected in Preferences → Providers → AWS Bedrock → Authentication.

### Access keys (default)

Provide static AWS credentials through Settings or the environment inherited by CodexBar/the CLI:

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

### AWS profile

Resolve credentials from a named profile in `~/.aws/config` / `~/.aws/credentials` instead of pasting keys. Set the
profile name in Settings (or via `AWS_PROFILE`). CodexBar shells out to the AWS CLI
(`aws configure export-credentials --profile <name>`), so this works with **SSO**, **assume-role**,
`credential_process`, and MFA-cached profiles — not just static credentials.

Requirements:

- AWS CLI v2 on your `PATH` (CodexBar also checks `/opt/homebrew/bin/aws`, `/usr/local/bin/aws`, and `~/.local/bin/aws`).
  Override the location with `AWS_CLI_PATH` if it lives elsewhere.
- For SSO profiles, an active session (`aws sso login --profile <name>`). Credentials are resolved fresh on each
  refresh; the AWS CLI caches the SSO token, so this does not re-prompt unless the session has expired.

The profile's region is read automatically (`aws configure get region`); leave the Region field blank to use it, or set
`AWS_REGION` / the Region field to override.

Relevant environment variables:

```bash
export CODEXBAR_BEDROCK_AUTH_MODE="profile"   # set automatically by Settings; "keys" or "profile"
export AWS_PROFILE="work"
export AWS_CLI_PATH="/opt/homebrew/bin/aws"   # optional override
```

The AWS identity (from either mode) must have permission to call Cost Explorer APIs, including `ce:GetCostAndUsage`.
Grant `cloudwatch:GetMetricData` to add the optional Claude activity totals. Without that permission, cost and budget
tracking continue unchanged.

## Data source

- Service: AWS Cost Explorer.
- Region: `AWS_REGION` or `AWS_DEFAULT_REGION`, defaulting to `us-east-1`.
- Usage: current-month Bedrock spend and historical daily cost buckets.
- Claude activity: rolling 14-day input tokens, output tokens, and requests from the configured region's `AWS/Bedrock`
  CloudWatch metrics. Other model families are excluded.
- Budget: `CODEXBAR_BEDROCK_BUDGET`, when set to a positive dollar amount.
- Test override: `CODEXBAR_BEDROCK_API_URL` replaces the Cost Explorer endpoint; use HTTPS or loopback HTTP.
- Test override: `CODEXBAR_BEDROCK_CLOUDWATCH_API_URL` replaces the CloudWatch endpoint; use HTTPS or loopback HTTP.

## Display

- Shows month-to-date Bedrock spend.
- Shows budget progress when a budget is configured.
- Shows rolling 14-day Claude tokens and requests when CloudWatch access is available.
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
- To include Claude token/request totals, confirm the principal can call `cloudwatch:GetMetricData` in the configured
  region.
- If using temporary credentials, include `AWS_SESSION_TOKEN`.
- In profile mode, confirm the AWS CLI is installed (or set `AWS_CLI_PATH`) and that the profile name is correct.

### "AWS profile session expired"

The profile's SSO/temporary session has expired. Run `aws sso login --profile <name>` (or refresh the underlying
credentials) and retry.

### "AWS CLI not found"

Profile mode requires AWS CLI v2. Install it (e.g. `brew install awscli`) or point CodexBar at the binary with
`AWS_CLI_PATH`.

### Wrong region

Set `AWS_REGION` or `AWS_DEFAULT_REGION`. Bedrock usage is regional, but Cost Explorer itself is account-level; CodexBar still needs a signing region for the request.

## Key files

- `Sources/CodexBarCore/Providers/Bedrock/BedrockProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Bedrock/BedrockSettingsReader.swift`
- `Sources/CodexBarCore/Providers/Bedrock/BedrockProfileCredentialProvider.swift`
- `Sources/CodexBarCore/Providers/Bedrock/BedrockUsageStats.swift`
- `Sources/CodexBarCore/Providers/Bedrock/BedrockAWSSigner.swift`
