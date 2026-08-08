---
summary: "IBM Bob authentication and Bobcoin usage tracking."
read_when:
  - Configuring IBM Bob in CodexBar
  - Debugging IBM Bob API-key or Bobcoin usage errors
---

# IBM Bob

CodexBar reads monthly Bobcoin usage from IBM Bob's profile and per-team budget APIs. It aggregates every team visible
to the configured key and follows the regional API host returned for each subscription instance.

## Authentication

Create an API key in the IBM Bob web portal, then add it to CodexBar's provider settings/token accounts or set:

```bash
export BOBSHELL_API_KEY="your-api-key"
```

CodexBar sends credentials only to HTTPS hosts under `bob.ibm.com`. API keys and JWT-based Bob sessions use the same
authorization formats as Bob Shell.

## Data shown

- Bobcoins used and the configured budget for each visible team.
- Aggregated monthly usage percentage when every team has a finite budget.
- The subscription refresh date and plan names when IBM returns them.

IBM documents Bobcoins as a monthly consumption metric. A team with an unlimited budget is shown as usage-only and is
not converted into a percentage.
