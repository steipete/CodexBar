---
summary: "Claude Platform on AWS month-to-date spend, 30-day cost and token history, and per-workspace spend through the Usage and Cost Analytics API."
provider_id: claudeplatformaws
provider_name: Claude Platform on AWS
provider_source: Long-lived AWS access key plus the workspace regions for month-to-date spend, 30-day daily cost and token history, and per-workspace and per-region spend.
plugin_scope: Script-signed SigV4 GETs to the fixed regional analytics endpoints on both engines; no AWS profile, session token, or Cost Explorer access.
read_when:
  - Configuring Claude Platform on AWS
  - Debugging Claude Platform on AWS usage fetching
---

# Claude Platform on AWS

[Claude Platform on AWS](https://platform.claude.com/docs/en/build-with-claude/claude-platform-on-aws) is the Claude
API operated by Anthropic and billed through AWS Marketplace. Its usage appears neither in the AWS Bedrock provider,
which reads Bedrock service charges, nor in the [Claude Platform](claudeplatform.md) provider, which reads a Console
prepaid balance.

Enable **Claude Platform on AWS** in Settings → Providers and enter:

- **Access key ID** and **Secret access key**: a long-lived IAM user access key, or set
  `ANTHROPIC_AWS_ACCESS_KEY_ID` and `ANTHROPIC_AWS_SECRET_ACCESS_KEY` for the CLI. Both are saved in CodexBar's local
  config file. Temporary credentials with a session token are not supported.
- **Regions**: the comma-separated AWS regions that hold your workspaces (for example `us-west-2, us-east-1`), or set
  `ANTHROPIC_AWS_REGIONS`. Each regional endpoint reports only the workspaces bound to its region, so CodexBar reads
  every listed region and sums them.

CodexBar deliberately does not read the standard `AWS_ACCESS_KEY_ID` variables or an AWS profile, so ambient AWS
credentials are never sent to this service by accident.

## Permissions

The IAM identity needs, on `Resource: "*"`:

| Action | Purpose |
| --- | --- |
| `aws-external-anthropic:ListAccountCost` | Month-to-date and daily cost |
| `aws-external-anthropic:ListAccountUsage` | Daily token counts for the 30-day history |
| `aws-external-anthropic:ListWorkspaces` | Optional: workspace names instead of IDs |
| `sts:GetWebIdentityToken`, `sts:TagGetWebIdentityToken` | The gateway mints a token as the caller on every request |

The AWS account also needs outbound web identity federation enabled once
(`aws iam enable-outbound-web-identity-federation`). The IAM policy editor may warn that the two analytics actions do
not exist; the gateway still evaluates them.

## What it shows

The bundled JavaScript plugin signs read-only GET requests with Signature Version 4 inside the script, because the
plugin host has no AWS credential or SigV4 support, and sends them only to
`https://aws-external-anthropic.<region>.api.aws`:

- **This month**: month-to-date cost from `GET /v1/organizations/analytics/cost`, grouped by workspace and summed
  across regions. This is also the cost meter.
- **Today**: the month total less this month's completed UTC days.
- **30-day history**: daily cost, requests, and input and output tokens (from `/v1/organizations/analytics/usage`),
  shown in the inline spend dashboard and in Usage & Spend. Days are UTC days.
- **By region** (with more than one region) and **By workspace** (top ten by spend).
- **At list prices** when it differs from the charged amount, the request count, and **Data as of**, the oldest
  refresh watermark among the regions.

Missing daily or token series leave the month total in place and omit the 30-day history rather than inventing
zeros. A region that fails its month-total request fails the refresh and is named in the error, because a partial
sum would understate spend.

## Limits

- Amounts are Anthropic's analytics figures (after discounts, before credits). AWS bills in Claude Consumption Units,
  so the AWS Marketplace invoice and Cost Explorer remain the billing source of truth.
- Data typically lags by about 4 hours and can take up to 24. Values can be revised until about a week after the
  month ends.
- The analytics API is in beta; field names may change.
- A plugin manifest declares at most 16 origins, so 16 common commercial regions are supported: `us-east-1`,
  `us-east-2`, `us-west-1`, `us-west-2`, `ca-central-1`, `sa-east-1`, `eu-west-1`, `eu-west-2`, `eu-west-3`,
  `eu-central-1`, `eu-north-1`, `ap-south-1`, `ap-northeast-1`, `ap-northeast-2`, `ap-southeast-1`, and
  `ap-southeast-2`.
- Claude Platform on AWS API keys (Bearer tokens) are not supported yet.
