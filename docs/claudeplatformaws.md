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

- **Monthly budget** and **Daily budget** (optional, USD): amounts to compare spend with, or set
  `ANTHROPIC_AWS_MONTHLY_BUDGET` and `ANTHROPIC_AWS_DAILY_BUDGET`. They add the Today and This month usage bars and
  never cap AWS billing.
- **Time zone** (optional): `local` (the default, this Mac's time zone) or `utc`, or set `ANTHROPIC_AWS_TIME_ZONE`.
  It decides where days and months begin for every figure below.

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
- **Today**: spend for the current day so far, in the configured time zone (the API rounds it down to the hour).
- **Projected this month**: the month so far plus the average of the last seven completed days for the time left
  after the data watermark. Shown only when at least three of those days had spend; it never changes the reported
  spend or the cost meter.
- **30-day history**: daily cost, requests, and input and output tokens (from `/v1/organizations/analytics/usage`)
  per model, shown in the inline spend dashboard and in Usage & Spend. Days follow the configured time zone.
- **By region** (with more than one region).
- **By model / By workspace**: one breakdown at a time, chosen with two pickers on the card: **Model** (top eight;
  spend without a model, such as code execution, is listed as Other usage) or **Workspace** (top ten), over
  **30d** (the last 30 days), **MTD** (month to date), **7d** (the last seven days including today), **Yesterday**, or
  **Today**. Percentages are shares of the selected period. The choice is remembered. The CLI lists all ten
  breakdowns.
- **Today** and **This month** usage bars when the optional budgets are set, plus the date a monthly budget would
  run out at the seven-day average.
- **At list prices** when it differs from the charged amount, the request count, **Data as of** (the oldest
  refresh watermark among the regions), and **Next data expected** (four hours after that watermark).

The API buckets days in UTC. With `utc`, CodexBar reads daily buckets plus today as its own range. With `local`, it
reads hourly buckets and cuts days at local midnight, which takes more rows and, for busy accounts, more pages per
refresh; an hour is the finest bucket it reads, so in a zone whose offset is not a
whole hour (UTC+05:30, for example) the hour that straddles local midnight counts toward the earlier day, in the
month total, Today, the history, and the period breakdowns alike. Use `utc` there for exact days. Series longer than one
page are read by following the cursor, up to 20 pages.

Missing daily or token series leave the month total in place and omit the 30-day history, and every breakdown
period except the month to date, rather than inventing zeros. A region that fails its month-total request fails the refresh and is named in the error, because a partial
sum would understate spend.

## Refresh behavior

Analytics data changes only when its watermark advances, typically every four hours, so most refreshes would
re-read identical numbers. Each region's last complete result is therefore kept in memory:

- Until four hours after the watermark, refreshes reuse it and re-check the region at most once an hour.
- After that, a single month-total request (at most every ten minutes) looks for a newer watermark.
- Only a newer watermark triggers the cost and token series requests (four per region with `utc`, two with
  `local`, plus any further pages).

Four hours is the documented typical cadence, used as a hint for when to look, not as a schedule. The kept result
is dropped at midnight in the configured time zone, when the Mac's time zone changes in `local` mode, and when
CodexBar restarts, is never written to disk, and is not used when its daily or
token series was unavailable. A manual refresh follows the same rules, so during the quiet period it can show data
up to an hour older than the API has.

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
